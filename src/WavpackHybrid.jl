module WavPackHybridFinalToy

export encode, decode, test_codec

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
function LMS()
    LMS(zeros(Int32, MAX_TAPS), zeros(Int32, MAX_TAPS))
end

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

function lms_update!(s::LMS, err::Int32, sample::Int32)
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
    # update history with reconstructed sample, not residual
    @inbounds for i in MAX_TAPS:-1:2
        s.history[i] = s.history[i-1]
    end
    s.history[1] = sample
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
function BitWriter() BitWriter(UInt8[],0x00,0) end

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
function BitReader(data::Vector{UInt8}) BitReader(data,1,0x00,0) end

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
# Encoder
# -------------------------
function encode(X::Matrix{Int16}; blocksize::Int=1024)
    N,C = size(X)
    @assert C==2 "Only stereo supported"
    lms = [LMS(),LMS()]
    bw = BitWriter()

    for n in 1:N
        L = Int32(X[n,1])
        R = Int32(X[n,2])

        predL = lms_predict(lms[1])
        predR = lms_predict(lms[2])
        errL = L - predL
        errR = R - predR

        shiftL = compute_shift(errL)
        shiftR = compute_shift(errR)
        qL,cL = split_residual(errL,shiftL)
        qR,cR = split_residual(errR,shiftR)

        kqL = compute_rice_k(qL)
        kcL = compute_rice_k(cL)
        kqR = compute_rice_k(qR)
        kcR = compute_rice_k(cR)

        # write shifts + k values
        write_bits!(bw,UInt32(shiftL),4)
        write_bits!(bw,UInt32(kqL),4)
        write_bits!(bw,UInt32(kcL),4)
        write_bits!(bw,UInt32(shiftR),4)
        write_bits!(bw,UInt32(kqR),4)
        write_bits!(bw,UInt32(kcR),4)

        # encode residuals
        rice_encode(bw,qL,kqL)
        rice_encode(bw,cL,kcL)
        rice_encode(bw,qR,kqR)
        rice_encode(bw,cR,kcR)

        # update LMS with reconstructed sample
        lms_update!(lms[1], errL, L)
        lms_update!(lms[2], errR, R)
    end
    flush_bits!(bw)
    return bw.data
end

# -------------------------
# Decoder
# -------------------------
function decode(bs::Vector{UInt8}, N::Int; blocksize::Int=1024)
    C=2
    lms=[LMS(),LMS()]
    br = BitReader(bs)
    Xrec = zeros(Int16,N,C)

    for n in 1:N
        shiftL = Int(read_bits!(br,4))
        kqL    = Int(read_bits!(br,4))
        kcL    = Int(read_bits!(br,4))
        shiftR = Int(read_bits!(br,4))
        kqR    = Int(read_bits!(br,4))
        kcR    = Int(read_bits!(br,4))

        qL = rice_decode(br,kqL)
        cL = rice_decode(br,kcL)
        qR = rice_decode(br,kqR)
        cR = rice_decode(br,kcR)

        errL = (qL<<shiftL)+cL
        errR = (qR<<shiftR)+cR

        L = lms_predict(lms[1]) + errL
        R = lms_predict(lms[2]) + errR

        Xrec[n,1] = clamp16(L)
        Xrec[n,2] = clamp16(R)

        lms_update!(lms[1], errL, L)
        lms_update!(lms[2], errR, R)
    end
    return Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running WavPackHybridFinalToy test...")
    X = rand(Int16,5000,2)
    bs = encode(X)
    Xrec = decode(bs,5000)
    if X==Xrec
        println("✅ Perfect reconstruction")
    else
        diff = sum(abs.(Int32.(X)-Int32.(Xrec)))
        println("❌ Mismatch, total error = $diff")
    end
end

end

using .WavPackHybridFinalToy
WavPackHybridFinalToy.test_codec()
