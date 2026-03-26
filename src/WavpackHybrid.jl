module WavPackHybridNoiseToy

export hybrid_encode, hybrid_decode, test_hybrid_noise_codec

# -------------------------
# Constants
# -------------------------
const MAX_TAPS = 8
const WEIGHT_SHIFT = 10
const UPDATE_TABLE = Int32[0,1,2,2,3,3,4,4,5,6,7,8,9,10,12,14]
const HYBRID_SHIFT_TABLE = [0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7]

# -------------------------
# LMS Predictor
# -------------------------
mutable struct LMS
    weights::Vector{Int32}
    history::Vector{Int32}
end
LMS() = LMS(zeros(Int32, MAX_TAPS), zeros(Int32, MAX_TAPS))

@inline function clamp16(x::Int32)
    return Int16(clamp(x, typemin(Int16), typemax(Int16)))
end

@inline function get_delta(sample::Int32)
    mag = abs(sample)
    idx = min(15, (32 - leading_zeros(UInt32(mag))) >> 1)
    return UPDATE_TABLE[idx + 1]
end

function lms_predict(s::LMS)
    acc = Int32(0)
    @inbounds for i in 1:MAX_TAPS
        acc += (s.weights[i] * s.history[i]) >> WEIGHT_SHIFT
    end
    return acc
end

function lms_update!(s::LMS, err::Int32)
    if err == 0 return end
    err_sign = err > 0 ? 1 : -1
    @inbounds for i in 1:MAX_TAPS
        h = s.history[i]
        if h != 0
            delta = get_delta(h)
            h_sign = h > 0 ? 1 : -1
            s.weights[i] += (h_sign == err_sign ? delta : -delta)
            s.weights[i] = clamp(s.weights[i], -2048, 2048)
        end
    end
    @inbounds for i in MAX_TAPS:-1:2
        s.history[i] = s.history[i-1]
    end
end

# -------------------------
# Residual splitting
# -------------------------
function compute_shift(err::Int32)
    idx = min(abs(err),15)+1
    return HYBRID_SHIFT_TABLE[idx]
end

function split_residual(err::Int32, shift::Int)
    q = err >> shift
    recon = q << shift
    c = err - recon
    return Int32(q), Int32(c)
end

function compute_rice_k(x::Int32)
    mag = max(abs(x),1)
    return clamp(fld(31 - leading_zeros(UInt32(mag)),2), 0, 15)
end

# -------------------------
# BitWriter / BitReader
# -------------------------
mutable struct BitWriter
    data::Vector{UInt8}
    buffer::UInt8
    bits_filled::Int
end
BitWriter() = BitWriter(UInt8[],0x00,0)

function write_bits!(bw::BitWriter, value::UInt32, nbits::Int)
    while nbits>0
        space = 8 - bw.bits_filled
        take = min(space, nbits)
        mask = (1 << take) - 1
        bw.buffer |= UInt8(((value >> (nbits - take)) & mask) << (space - take))
        bw.bits_filled += take
        nbits -= take
        if bw.bits_filled == 8
            push!(bw.data,bw.buffer)
            bw.buffer=0x00
            bw.bits_filled=0
        end
    end
end

function flush_bits!(bw::BitWriter)
    if bw.bits_filled>0
        push!(bw.data,bw.buffer)
        bw.buffer=0x00
        bw.bits_filled=0
    end
end

function write_unary!(bw::BitWriter,value::Int)
    for _ in 1:value
        write_bits!(bw,UInt32(1),1)
    end
    write_bits!(bw,UInt32(0),1)
end

function rice_encode(bw::BitWriter,x::Int32,k::Int)
    u = UInt32(x<0 ? (-x<<1)-1 : x<<1)
    q = u >> k
    r = u & ((1<<k)-1)
    write_unary!(bw,Int(q))
    write_bits!(bw,UInt32(r),k)
end

mutable struct BitReader
    data::Vector{UInt8}
    pos::Int
    buffer::UInt8
    bits_left::Int
end
BitReader(data::Vector{UInt8}) = BitReader(data,1,0x00,0)

function read_bits!(br::BitReader, nbits::Int)
    result = UInt32(0)
    while nbits>0
        if br.bits_left==0
            br.buffer = br.data[br.pos]
            br.pos += 1
            br.bits_left=8
        end
        take = min(nbits,br.bits_left)
        result <<= take
        shift = br.bits_left - take
        result |= UInt32((br.buffer >> shift) & ((1<<take)-1))
        br.bits_left -= take
        nbits -= take
    end
    return result
end

function read_unary!(br::BitReader)
    count=0
    while read_bits!(br,1)!=0
        count+=1
    end
    return count
end

function rice_decode(br::BitReader,k::Int)
    q=read_unary!(br)
    r=read_bits!(br,k)
    u=(q<<k)|r
    return Int32((u&1)!=0 ? -((u+1)>>1) : (u>>1))
end

# -------------------------
# Noise Shaper
# -------------------------
mutable struct Shaper
    feedback::Int32
end
Shaper() = Shaper(0)

# -------------------------
# Hybrid Lossless + Noise Shaping Encoder
# -------------------------
function hybrid_encode(X::Matrix{Int16})
    N,C = size(X)
    @assert C==2 "Only stereo supported"
    lms = [LMS(),LMS()]
    shapers = [Shaper(),Shaper()]
    lossy_bw = BitWriter()
    corr_bw  = BitWriter()

    for n in 1:N
        L = Int32(X[n,1])
        R = Int32(X[n,2])

        # Joint stereo
        mid  = L - (R >> 1)
        side = R

        predM = lms_predict(lms[1])
        predS = lms_predict(lms[2])
        errM = mid - predM
        errS = side - predS

        # --- Noise shaping feedback ---
        shapedM = errM + (shapers[1].feedback >> 3)
        shapedS = errS + (shapers[2].feedback >> 3)

        shiftM = compute_shift(shapedM)
        shiftS = compute_shift(shapedS)
        qM,cM = split_residual(shapedM,shiftM)
        qS,cS = split_residual(shapedS,shiftS)

        # Update feedback for shaping
        shapers[1].feedback = shapedM - ((qM<<shiftM)+cM)
        shapers[2].feedback = shapedS - ((qS<<shiftS)+cS)

        # --- Write lossy stream (q only) ---
        write_bits!(lossy_bw,UInt32(shiftM),4)
        write_bits!(lossy_bw,UInt32(shiftS),4)
        kM = compute_rice_k(qM)
        kS = compute_rice_k(qS)
        write_bits!(lossy_bw,UInt32(kM),4)
        write_bits!(lossy_bw,UInt32(kS),4)
        rice_encode(lossy_bw,qM,kM)
        rice_encode(lossy_bw,qS,kS)

        # --- Write correction stream (c only) ---
        write_bits!(corr_bw,UInt32(shiftM),4)
        write_bits!(corr_bw,UInt32(shiftS),4)
        kMc = compute_rice_k(cM)
        kSc = compute_rice_k(cS)
        write_bits!(corr_bw,UInt32(kMc),4)
        write_bits!(corr_bw,UInt32(kSc),4)
        rice_encode(corr_bw,cM,kMc)
        rice_encode(corr_bw,cS,kSc)

        # Update LMS with full original residuals
        lms_update!(lms[1], errM)
        lms_update!(lms[2], errS)
        lms[1].history[1] += errM
        lms[2].history[1] += errS
    end

    flush_bits!(lossy_bw)
    flush_bits!(corr_bw)
    return lossy_bw.data, corr_bw.data
end

# -------------------------
# Hybrid Lossless + Noise Shaping Decoder
# -------------------------
function hybrid_decode(lossy::Vector{UInt8}, corr::Vector{UInt8}, N::Int)
    lms = [LMS(),LMS()]
    lossy_br = BitReader(lossy)
    corr_br  = BitReader(corr)
    Xrec = zeros(Int16,N,2)

    for n in 1:N
        shiftM = Int(read_bits!(lossy_br,4))
        shiftS = Int(read_bits!(lossy_br,4))
        kM = Int(read_bits!(lossy_br,4))
        kS = Int(read_bits!(lossy_br,4))
        qM = rice_decode(lossy_br,kM)
        qS = rice_decode(lossy_br,kS)

        shiftMc = Int(read_bits!(corr_br,4))
        shiftSc = Int(read_bits!(corr_br,4))
        kMc = Int(read_bits!(corr_br,4))
        kSc = Int(read_bits!(corr_br,4))
        cM = rice_decode(corr_br,kMc)
        cS = rice_decode(corr_br,kSc)

        errM = (qM << shiftM) + cM
        errS = (qS << shiftS) + cS

        mid  = lms_predict(lms[1]) + errM
        side = lms_predict(lms[2]) + errS
        L = mid + (side >> 1)
        R = side

        Xrec[n,1] = clamp16(L)
        Xrec[n,2] = clamp16(R)

        lms_update!(lms[1], errM)
        lms_update!(lms[2], errS)
        lms[1].history[1] += errM
        lms[2].history[1] += errS
    end
    return Xrec
end

# -------------------------
# Test
# -------------------------
function test_hybrid_noise_codec()
    println("Running WavPackHybridNoiseToy test...")
    X = rand(Int16,5000,2)
    lossy, corr = hybrid_encode(X)
    Xrec = hybrid_decode(lossy,corr,5000)
    if X==Xrec
        println("✅ Perfect reconstruction")
    else
        diff = sum(abs.(Int32.(X)-Int32.(Xrec)))
        println("❌ Mismatch, total error = $diff")
    end
end

end

# -------------------------
# Run test
# -------------------------
using .WavPackHybridNoiseToy
WavPackHybridNoiseToy.test_hybrid_noise_codec()
