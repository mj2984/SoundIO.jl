module WavPackHybridFinalToyV13

export encode, decode, test_codec

# -------------------------
# Constants
# -------------------------
const MAX_TAPS = 8
const WEIGHT_SHIFT = 10
const UPDATE_TABLE = Int32[0,1,2,2,3,3,4,4,5,6,7,8,9,10,12,14]
const BLOCKSIZE = 1024

# -------------------------
# LMS
# -------------------------
mutable struct LMS
    weights::Vector{Int32}
    history::Vector{Int32}
end
LMS() = LMS(zeros(Int32, MAX_TAPS), zeros(Int32, MAX_TAPS))

@inline clamp16(x::Int32) = Int16(clamp(x, typemin(Int16), typemax(Int16)))

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
    acc
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
# Rice Coding
# -------------------------
function compute_rice_k(x::Int32)
    mag = max(abs(x),1)
    return clamp(fld(31 - leading_zeros(UInt32(mag)),2), 0, 15)
end

function split_residual(err::Int32, shift::Int)
    q = err >> shift
    c = err - (q << shift)
    return q, c
end

# -------------------------
# Bit IO
# -------------------------
mutable struct BitWriter
    data::Vector{UInt8}
    buffer::UInt8
    bits_filled::Int
end
BitWriter() = BitWriter(UInt8[],0x00,0)

function write_bits!(bw::BitWriter, value::Integer, nbits::Int)
    v = UInt32(value)
    while nbits>0
        space = 8 - bw.bits_filled
        take = min(space, nbits)
        mask = (1 << take) - 1
        bw.buffer |= UInt8(((v >> (nbits - take)) & mask) << (space - take))
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
    end
end

function write_unary!(bw::BitWriter,value::Int)
    for _ in 1:value
        write_bits!(bw,1,1)
    end
    write_bits!(bw,0,1)
end

function rice_encode(bw::BitWriter,x::Int32,k::Int)
    u = UInt32(x<0 ? (-x<<1)-1 : x<<1)
    q = u >> k
    r = u & ((1<<k)-1)
    write_unary!(bw,Int(q))
    write_bits!(bw,r,k)
end

mutable struct BitReader
    data::Vector{UInt8}
    pos::Int
    buffer::UInt8
    bits_left::Int
end
BitReader(d) = BitReader(d,1,0x00,0)

function read_bits!(br::BitReader, nbits::Int)
    result = UInt32(0)
    while nbits>0
        if br.bits_left==0
            br.buffer = br.data[br.pos]; br.pos+=1; br.bits_left=8
        end
        take=min(nbits,br.bits_left)
        result <<= take
        shift = br.bits_left - take
        result |= UInt32((br.buffer >> shift) & ((1<<take)-1))
        br.bits_left -= take
        nbits -= take
    end
    result
end

function read_unary!(br::BitReader)
    c=0
    while read_bits!(br,1)!=0
        c+=1
    end
    c
end

function rice_decode(br::BitReader,k::Int)
    q=read_unary!(br)
    r=read_bits!(br,k)
    u=(q<<k)|r
    Int32((u&1)!=0 ? -((u+1)>>1) : (u>>1))
end

# -------------------------
# Hybrid shift selection
# -------------------------
function select_shift(res::Vector{Int32})
    best_shift=0
    best_score=typemax(Int)
    for s in 0:7
        score = sum(abs.(res .>> s))
        if score < best_score
            best_score = score
            best_shift = s
        end
    end
    best_shift
end

# -------------------------
# Encoder
# -------------------------
function encode(X::Matrix{Int16}; blocksize::Int=BLOCKSIZE)
    N,_ = size(X)
    lmsL,lmsR = LMS(),LMS()
    bw=BitWriter()

    for b in 1:blocksize:N
        bend=min(b+blocksize-1,N)
        Ns=bend-b+1

        errL = Vector{Int32}(undef,Ns)
        errR = Vector{Int32}(undef,Ns)

        # compute residuals
        for i in 1:Ns
            L=Int32(X[b+i-1,1])
            R=Int32(X[b+i-1,2])
            eL = L - lms_predict(lmsL)
            eR = R - lms_predict(lmsR)
            errL[i]=eL; errR[i]=eR
            lms_update!(lmsL,eL,L)
            lms_update!(lmsR,eR,R)
        end

        shiftL = select_shift(errL)
        shiftR = select_shift(errR)

        write_bits!(bw,UInt32(shiftL),4)
        write_bits!(bw,UInt32(shiftR),4)

        # encode
        for i in 1:Ns
            for (err,shift) in ((errL[i],shiftL),(errR[i],shiftR))
                q,c = split_residual(err,shift)

                kq=compute_rice_k(q)
                kc=compute_rice_k(c)

                write_bits!(bw,UInt32(kq),4)
                write_bits!(bw,UInt32(kc),4)

                rice_encode(bw,q,kq)
                rice_encode(bw,c,kc)
            end
        end
    end

    flush_bits!(bw)
    return bw.data
end

# -------------------------
# Decoder
# -------------------------
function decode(bs::Vector{UInt8}, N::Int; blocksize::Int=BLOCKSIZE)
    lmsL,lmsR=LMS(),LMS()
    br=BitReader(bs)
    Xrec=zeros(Int16,N,2)

    pos=1
    while pos<=N
        bend=min(pos+blocksize-1,N)
        Ns=bend-pos+1

        shiftL=Int(read_bits!(br,4))
        shiftR=Int(read_bits!(br,4))

        for i in 1:Ns
            vals=Int32[]
            for shift in (shiftL,shiftR)
                kq=Int(read_bits!(br,4))
                kc=Int(read_bits!(br,4))
                q=rice_decode(br,kq)
                c=rice_decode(br,kc)
                push!(vals,(q<<shift)+c)
            end

            L = lms_predict(lmsL)+vals[1]
            R = lms_predict(lmsR)+vals[2]

            Xrec[pos,1]=clamp16(L)
            Xrec[pos,2]=clamp16(R)

            lms_update!(lmsL,vals[1],L)
            lms_update!(lmsR,vals[2],R)

            pos+=1
        end
    end

    Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running V13 test...")
    X = rand(Int16,5000,2)
    bs = encode(X)
    Xrec = decode(bs,5000)
    if X==Xrec
        println("✅ Perfect reconstruction")
    else
        println("❌ Error")
    end
end

end

using .WavPackHybridFinalToyV13
WavPackHybridFinalToyV13.test_codec()
