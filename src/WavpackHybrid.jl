module WavPackHybridFinalToyV19Fixed

export encode, decode_lossless, test_codec

# -------------------------
# Constants
# -------------------------
const MAX_TAPS = 8
const WEIGHT_SHIFT = 10
const UPDATE_TABLE = Int32[0,1,2,2,3,3,4,4,5,6,7,8,9,10,12,14]
const BLOCKSIZE = 1024

# -------------------------
# Utils
# -------------------------
@inline clamp16(x::Int32) = Int16(clamp(x, typemin(Int16), typemax(Int16)))

function compute_rice_k(x::Int32)
    mag = max(abs(x),1)
    clamp(fld(31 - leading_zeros(UInt32(mag)),2), 0, 15)
end

# -------------------------
# LMS
# -------------------------
mutable struct LMS
    weights::Vector{Int32}
    history::Vector{Int32}
end
LMS() = LMS(zeros(Int32,MAX_TAPS), zeros(Int32,MAX_TAPS))

@inline function get_delta(sample::Int32)
    mag = abs(sample)
    idx = min(15, (32 - leading_zeros(UInt32(mag))) >> 1)
    UPDATE_TABLE[idx+1]
end

function lms_predict(s::LMS)
    acc=Int32(0)
    @inbounds for i in 1:MAX_TAPS
        acc += (s.weights[i]*s.history[i]) >> WEIGHT_SHIFT
    end
    acc
end

function lms_update!(s::LMS, err::Int32, sample::Int32)
    if err==0 return end
    sign = err>0 ? 1 : -1
    @inbounds for i in 1:MAX_TAPS
        h=s.history[i]
        if h!=0
            delta=get_delta(h)
            s.weights[i]+= (h>0)==(sign>0) ? delta : -delta
            s.weights[i]=clamp(s.weights[i],-2048,2048)
        end
    end
    @inbounds for i in MAX_TAPS:-1:2
        s.history[i]=s.history[i-1]
    end
    s.history[1]=sample
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
    v=UInt32(value)
    while nbits>0
        space=8-bw.bits_filled
        take=min(space,nbits)
        mask=(1<<take)-1
        bw.buffer |= UInt8(((v>>(nbits-take))&mask)<<(space-take))
        bw.bits_filled+=take
        nbits-=take
        if bw.bits_filled==8
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

function write_unary!(bw,v)
    for _ in 1:v
        write_bits!(bw,1,1)
    end
    write_bits!(bw,0,1)
end

function rice_encode(bw,x::Int32,k)
    u=UInt32(x<0 ? (-x<<1)-1 : x<<1)
    q=u>>k; r=u&((1<<k)-1)
    write_unary!(bw,Int(q))
    write_bits!(bw,r,k)
end

mutable struct BitReader
    data::Vector{UInt8}
    pos::Int
    buffer::UInt8
    bits_left::Int
end
BitReader(d)=BitReader(d,1,0x00,0)

function read_bits!(br,n)
    r=UInt32(0)
    while n>0
        if br.bits_left==0
            br.buffer=br.data[br.pos]; br.pos+=1; br.bits_left=8
        end
        take=min(n,br.bits_left)
        r <<= take
        shift=br.bits_left-take
        r |= UInt32((br.buffer>>shift)&((1<<take)-1))
        br.bits_left-=take
        n-=take
    end
    r
end

function read_unary!(br)
    c=0
    while read_bits!(br,1)!=0
        c+=1
    end
    c
end

function rice_decode(br,k)
    q=read_unary!(br)
    r=read_bits!(br,k)
    u=(q<<k)|r
    Int32((u & 1) != 0 ? -((u + 1) >> 1) : (u >> 1))
end

# -------------------------
# Mid/Side
# -------------------------
function mid_side(L::Vector{Int32}, R::Vector{Int32})
    mid = (L .+ R) .>> 1
    side = L .- R
    return mid, side
end

# -------------------------
# Bit estimation
# -------------------------
function estimate_bits(v::Vector{Int32}, shift)
    total=0
    for x in v
        q = x >> shift
        total += abs(q) + 4
    end
    total
end

# -------------------------
# Encoder
# -------------------------
function encode(X::Matrix{Int16}; target_bps=4.0)
    N,_=size(X)

    lmsL,lmsR=LMS(),LMS()
    shapeL=Int32(0)
    shapeR=Int32(0)

    bwL=BitWriter()
    bwC=BitWriter()

    for b in 1:BLOCKSIZE:N
        bend=min(b+BLOCKSIZE-1,N)
        Ns=bend-b+1

        errL=Int32[]
        errR=Int32[]

        for i in 1:Ns
            L=Int32(X[b+i-1,1])
            R=Int32(X[b+i-1,2])
            eL=L-lms_predict(lmsL)
            eR=R-lms_predict(lmsR)
            push!(errL,eL); push!(errR,eR)
            lms_update!(lmsL,eL,L)
            lms_update!(lmsR,eR,R)
        end

        mid,side = mid_side(errL,errR)
        use_ms = estimate_bits(mid,2)+estimate_bits(side,2) <
                 estimate_bits(errL,2)+estimate_bits(errR,2)

        write_bits!(bwL,use_ms,1)

        A = use_ms ? mid : errL
        B = use_ms ? side : errR

        shiftA=2; shiftB=2

        write_bits!(bwL,shiftA,4)
        write_bits!(bwL,shiftB,4)

        for i in 1:Ns
            for (vec,shape,shift,isL) in ((A,shapeL,shiftA,true),(B,shapeR,shiftB,false))
                err = vec[i] + shape
                q = err >> shift
                c = err - (q<<shift)
                newshape = c - (shape >> 4)
                kq=compute_rice_k(q)
                kc=compute_rice_k(c)
                write_bits!(bwL,kq,4)
                rice_encode(bwL,q,kq)
                write_bits!(bwC,kc,4)
                rice_encode(bwC,c,kc)
                if isL
                    shapeL=newshape
                else
                    shapeR=newshape
                end
            end
        end
    end

    flush_bits!(bwL)
    flush_bits!(bwC)

    return bwL.data, bwC.data
end

# -------------------------
# Decoder (fixed)
# -------------------------
function decode_lossless(bsL, bsC, N)
    lmsL, lmsR = LMS(), LMS()
    shapeL = Int32(0)
    shapeR = Int32(0)

    brL = BitReader(bsL)
    brC = BitReader(bsC)

    Xrec = zeros(Int16, N, 2)

    pos = 1
    while pos <= N
        use_ms = read_bits!(brL, 1) != 0
        shiftA = Int(read_bits!(brL, 4))
        shiftB = Int(read_bits!(brL, 4))

        Ns = min(BLOCKSIZE, N - pos + 1)
        for _ in 1:Ns
            vals = Int32[]
            for (shape, shift, isL) in ((shapeL, shiftA, true), (shapeR, shiftB, false))
                kq = Int(read_bits!(brL, 4))
                q = rice_decode(brL, kq)
                kc = Int(read_bits!(brC, 4))
                c = rice_decode(brC, kc)

                err_shaped = (q << shift) + c
                err = err_shaped - shape
                newshape = c - (shape >> 4)

                push!(vals, err)
                if isL
                    shapeL = newshape
                else
                    shapeR = newshape
                end
            end

            if use_ms
                mid = vals[1]
                side = vals[2]
                vals[1] = mid + (side >> 1)
                vals[2] = mid - (side - (side >> 1))
            end

            resL, resR = vals[1], vals[2]

            L = lms_predict(lmsL) + resL
            R = lms_predict(lmsR) + resR

            Xrec[pos, 1] = clamp16(L)
            Xrec[pos, 2] = clamp16(R)

            lms_update!(lmsL, resL, L)
            lms_update!(lmsR, resR, R)

            pos += 1
        end
    end

    Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running V19Fixed test...")
    X = rand(Int16,5000,2)
    wv,wvc = encode(X)
    Xrec = decode_lossless(wv,wvc,5000)
    println(X==Xrec ? "✅ Perfect reconstruction" : "❌ Mismatch")
    println("Sizes → lossy: $(length(wv))  correction: $(length(wvc))")
end

end

using .WavPackHybridFinalToyV19Fixed
WavPackHybridFinalToyV19Fixed.test_codec()
