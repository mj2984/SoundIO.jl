module WavPackHybridFinalToyV8

export encode, decode, test_codec

# -------------------------
# Constants
# -------------------------
const MAX_TAPS = 8
const WEIGHT_SHIFT = 10
const UPDATE_TABLE = Int32[0,1,2,2,3,3,4,4,5,6,7,8,9,10,12,14]
const BLOCKSIZE = 1024

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
    @inbounds for i in MAX_TAPS:-1:2
        s.history[i] = s.history[i-1]
    end
    s.history[1] = sample
end

# -------------------------
# Residual splitting
# -------------------------
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
# Adaptive shift selection
# -------------------------
function select_block_shift(residuals::Vector{Int32})
    best_shift = 0
    best_score = typemax(Int)
    for shift in 0:7
        score = sum(abs.(residuals .>> shift))
        if score < best_score
            best_score = score
            best_shift = shift
        end
    end
    return best_shift
end

# -------------------------
# Encoder
# -------------------------
function encode(X::Matrix{Int16}; blocksize::Int=BLOCKSIZE, scale_factor::Float64=1.0)
    N,C = size(X)
    @assert C==2 "Only stereo supported"
    lmsL, lmsR = LMS(), LMS()
    bw = BitWriter()
    
    for bstart in 1:blocksize:N
        bend = min(bstart+blocksize-1,N)
        block = X[bstart:bend,:]
        Ns = size(block,1)
        err_block = zeros(Int32,Ns,2)
        
        # compute residuals
        for n in 1:Ns
            L = Int32(block[n,1])
            R = Int32(block[n,2])
            predL = lms_predict(lmsL)
            predR = lms_predict(lmsR)
            errL = L - predL
            errR = R - predR
            err_block[n,1] = errL
            err_block[n,2] = errR
            lms_update!(lmsL, errL, L)
            lms_update!(lmsR, errR, R)
        end
        
        # hybrid lossy + correction
        lossy_block = round.(Int32, err_block ./ scale_factor)
        correction_block = err_block - lossy_block .* Int32(scale_factor)
        
        # adaptive block shifts
        shiftA = select_block_shift(lossy_block[:,1])
        shiftB = select_block_shift(lossy_block[:,2])
        write_bits!(bw,UInt32(shiftA),4)
        write_bits!(bw,UInt32(shiftB),4)
        
        # encode lossy then correction
        for n in 1:Ns
            for ch in 1:2
                # lossy residual
                qL,cL = split_residual(lossy_block[n,ch], ch==1 ? shiftA : shiftB)
                kq = compute_rice_k(qL)
                kc = compute_rice_k(cL)
                write_bits!(bw,UInt32(kq),4)
                write_bits!(bw,UInt32(kc),4)
                rice_encode(bw,qL,kq)
                rice_encode(bw,cL,kc)
                
                # correction residual
                qC,cC = split_residual(correction_block[n,ch], ch==1 ? shiftA : shiftB)
                kqC = compute_rice_k(qC)
                kcC = compute_rice_k(cC)
                write_bits!(bw,UInt32(kqC),4)
                write_bits!(bw,UInt32(kcC),4)
                rice_encode(bw,qC,kqC)
                rice_encode(bw,cC,kcC)
            end
        end
    end
    
    flush_bits!(bw)
    return bw.data
end

# -------------------------
# Decoder
# -------------------------
function decode(bs::Vector{UInt8}, N::Int; blocksize::Int=BLOCKSIZE, scale_factor::Float64=1.0)
    lmsL, lmsR = LMS(), LMS()
    br = BitReader(bs)
    Xrec = zeros(Int16,N,2)
    pos = 1
    
    while pos <= N
        bend = min(pos+blocksize-1,N)
        Ns = bend-pos+1
        shiftA = Int(read_bits!(br,4))
        shiftB = Int(read_bits!(br,4))
        
        for n in 1:Ns
            lossy = zeros(Int32,2)
            correction = zeros(Int32,2)
            for ch in 1:2
                kq = Int(read_bits!(br,4))
                kc = Int(read_bits!(br,4))
                q = rice_decode(br,kq)
                c = rice_decode(br,kc)
                lossy[ch] = (q << (ch==1 ? shiftA : shiftB)) + c
                
                kqC = Int(read_bits!(br,4))
                kcC = Int(read_bits!(br,4))
                qC = rice_decode(br,kqC)
                cC = rice_decode(br,kcC)
                correction[ch] = (qC << (ch==1 ? shiftA : shiftB)) + cC
            end
            
            L32 = lms_predict(lmsL) + lossy[1]*Int32(scale_factor) + correction[1]
            R32 = lms_predict(lmsR) + lossy[2]*Int32(scale_factor) + correction[2]
            
            Xrec[pos,1] = clamp16(L32)
            Xrec[pos,2] = clamp16(R32)
            
            lms_update!(lmsL, lossy[1]*Int32(scale_factor)+correction[1], L32)
            lms_update!(lmsR, lossy[2]*Int32(scale_factor)+correction[2], R32)
            
            pos += 1
        end
    end
    
    return Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running WavPackHybridFinalToyV8 test...")
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

using .WavPackHybridFinalToyV8
WavPackHybridFinalToyV8.test_codec()
