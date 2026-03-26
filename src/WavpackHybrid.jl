module WavPackHybridBitrateToy

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
LMS() = LMS(zeros(Int32, MAX_TAPS), zeros(Int32, MAX_TAPS))

@inline function clamp16(x::Int32)
    Int16(clamp(x, typemin(Int16), typemax(Int16)))
end

@inline function get_delta(sample::Int32)
    mag = abs(sample)
    idx = min(15, (32 - leading_zeros(UInt32(mag))) >> 1)
    UPDATE_TABLE[idx+1]
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
    idx = min(abs(err), 15) + 1
    HYBRID_SHIFT_TABLE[idx]
end

function split_residual(err::Int32, shift::Int)
    q = err >> shift
    recon = q << shift
    c = err - recon
    return Int32(q), Int32(c)
end

function compute_rice_k(x::Int32)
    mag = max(abs(x),1)
    clamp(fld(31 - leading_zeros(UInt32(mag)),2), 0, 15)
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
            push!(bw.data, bw.buffer)
            bw.buffer = 0x00
            bw.bits_filled = 0
        end
    end
end

function flush_bits!(bw::BitWriter)
    if bw.bits_filled > 0
        push!(bw.data, bw.buffer)
        bw.buffer = 0x00
        bw.bits_filled = 0
    end
end

function write_unary!(bw::BitWriter, value::Int)
    for _ in 1:value
        write_bits!(bw, UInt32(1), 1)
    end
    write_bits!(bw, UInt32(0), 1)
end

function rice_encode(bw::BitWriter, x::Int32, k::Int)
    u = UInt32(x<0 ? (-x<<1)-1 : x<<1)
    q = u >> k
    r = u & ((1<<k)-1)
    write_unary!(bw, Int(q))
    write_bits!(bw, UInt32(r), k)
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
            br.bits_left = 8
        end
        take = min(nbits, br.bits_left)
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
    q = read_unary!(br)
    r = read_bits!(br,k)
    u = (q<<k)|r
    Int32((u&1)!=0 ? -((u+1)>>1) : (u>>1))
end

# -------------------------
# Hybrid Encoder (lossy + correction)
# -------------------------
function encode(X::Matrix{Int16}; blocksize::Int=1024, target_bps::Float64=8.0)
    N,C = size(X)
    @assert C==2 "Only stereo supported"

    lms = [LMS(), LMS()]
    lossy_bw = BitWriter()
    corr_bw  = BitWriter()

    idx = 1
    while idx <= N
        blk_end = min(idx+blocksize-1, N)

        for n in idx:blk_end
            L = Int32(X[n,1])
            R = Int32(X[n,2])

            # --- normal stereo residuals ---
            predL = lms_predict(lms[1])
            predR = lms_predict(lms[2])
            errL = L - predL
            errR = R - predR
            shiftL = compute_shift(errL)
            shiftR = compute_shift(errR)
            qL,cL = split_residual(errL, shiftL)
            qR,cR = split_residual(errR, shiftR)

            # --- joint stereo ---
            mid = L - (R>>1)
            side = R
            predM = lms_predict(lms[1])
            predS = lms_predict(lms[2])
            errM = mid - predM
            errS = side - predS
            shiftM = compute_shift(errM)
            shiftS = compute_shift(errS)
            qM,cM = split_residual(errM, shiftM)
            qS,cS = split_residual(errS, shiftS)

            sum_normal = abs(qL)+abs(cL)+abs(qR)+abs(cR)
            sum_joint  = abs(qM)+abs(cM)+abs(qS)+abs(cS)

            use_joint = sum_joint < sum_normal ? 1 : 0
            write_bits!(lossy_bw, UInt32(use_joint), 1)

            if use_joint==1
                channels = [(qM,cM,shiftM,lms[1]), (qS,cS,shiftS,lms[2])]
            else
                channels = [(qL,cL,shiftL,lms[1]), (qR,cR,shiftR,lms[2])]
            end

            for (q,c,shift,s) in channels
                write_bits!(lossy_bw, UInt32(shift), 4)
                kq = compute_rice_k(q)
                kc = compute_rice_k(c)
                write_bits!(lossy_bw, UInt32(kq), 4)
                write_bits!(lossy_bw, UInt32(kc), 4)
                rice_encode(lossy_bw, q, kq)
                rice_encode(lossy_bw, c, kc)

                # --- correction stream carries only residual not in lossy quantization ---
                corr_val = Int32(c)  # c is extra bits needed for perfect reconstruction
                rice_encode(corr_bw, corr_val, kc)

                # LMS update
                recon_err = (q<<shift) + c
                lms_update!(s, recon_err)
                s.history[1] += recon_err
            end
        end
        idx += blocksize
    end

    flush_bits!(lossy_bw)
    flush_bits!(corr_bw)
    return lossy_bw.data, corr_bw.data
end

# -------------------------
# Hybrid Decoder
# -------------------------
function decode(lossy::Vector{UInt8}, corr::Vector{UInt8}, N::Int; blocksize::Int=1024)
    C=2
    lms = [LMS(),LMS()]
    Xrec = zeros(Int16,N,C)

    lossy_br = BitReader(lossy)
    corr_br  = BitReader(corr)
    idx = 1

    while idx <= N
        blk_end = min(idx+blocksize-1, N)
        for n in idx:blk_end
            use_joint = read_bits!(lossy_br,1)
            decoded = zeros(Int32,2)

            for ch in 1:2
                s = lms[ch]
                shift = Int(read_bits!(lossy_br,4))
                kq = Int(read_bits!(lossy_br,4))
                kc = Int(read_bits!(lossy_br,4))
                q = rice_decode(lossy_br, kq)
                c_lossy = rice_decode(lossy_br, kc)
                corr_val = rice_decode(corr_br, kc)  # correction
                err = (q<<shift) + corr_val  # use correction only, not c_lossy
                sample = lms_predict(s) + err
                decoded[ch] = sample
                lms_update!(s, err)
                s.history[1] += err
            end

            if use_joint==1
                mid = decoded[1]
                side = decoded[2]
                L = mid + (side>>1)
                R = side
            else
                L = decoded[1]
                R = decoded[2]
            end

            Xrec[n,1] = clamp16(L)
            Xrec[n,2] = clamp16(R)
        end
        idx += blocksize
    end

    return Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running WavPackHybridBitrateToy test...")
    X = rand(Int16,5000,2)
    lossy, corr = encode(X)
    Xrec = decode(lossy, corr, 5000)
    if X==Xrec
        println("✅ Perfect reconstruction")
    else
        diff = sum(abs.(Int32.(X)-Int32.(Xrec)))
        println("❌ Mismatch, total error = $diff")
    end
end

end

using .WavPackHybridBitrateToy
WavPackHybridBitrateToy.test_codec()
