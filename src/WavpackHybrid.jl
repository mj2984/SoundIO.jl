module WavPackHybrid

include("SoundCore.jl")
using BitIntegers
export encode, decode, test_codec

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
@inline clamp_sample(x::Int32, ::Type{T}) where T =
    T === Int16 ? clamp(x, typemin(Int16), typemax(Int16)) :
    T === Int24 ? clamp(x, -8_388_608, 8_388_607) :
    x

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
# Bit IO and Rice coding
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
        bw.buffer=0
        bw.bits_filled=0
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
# Mid/Side & Bit Estimation
# -------------------------
function mid_side(L::Vector{Int32}, R::Vector{Int32})
    mid = (L .+ R) .>> 1
    side = L .- R
    return mid, side
end

function estimate_bits(v::Vector{Int32}, shift)
    total=0
    for x in v
        q = x >> shift
        total += abs(q) + 4
    end
    total
end

# -------------------------
# Encode / Decode
# -------------------------
function encode(X::AbstractVector{Stereo{T}}) where T<:Integer
    N = length(X)
    lmsL,lmsR=LMS(),LMS()
    bwL,bwC = BitWriter(),BitWriter()

    for b in 1:BLOCKSIZE:N
        bend=min(b+BLOCKSIZE-1,N)
        Ns=bend-b+1
        errL,errR = Int32[],Int32[]
        shapeL,shapeR = Int32(0),Int32(0)   # Reset shape per block

        for i in 1:Ns
            L,R = Int32(X[b+i-1].l), Int32(X[b+i-1].r)
            eL,eR = L-lms_predict(lmsL), R-lms_predict(lmsR)
            push!(errL,eL); push!(errR,eR)
            lms_update!(lmsL,eL,L)
            lms_update!(lmsR,eR,R)
        end

        mid,side = mid_side(errL,errR)
        use_ms = estimate_bits(mid,2)+estimate_bits(side,2) < estimate_bits(errL,2)+estimate_bits(errR,2)
        write_bits!(bwL,use_ms,1)

        A = use_ms ? mid : errL
        B = use_ms ? side : errR

        shiftA,shiftB = 2,2
        write_bits!(bwL,shiftA,4); write_bits!(bwL,shiftB,4)

        for i in 1:Ns
            for (vec,shape,shift,isL) in ((A,shapeL,shiftA,true),(B,shapeR,shiftB,false))
                err = vec[i] + shape
                q = err >> shift
                c = err - (q<<shift)
                newshape = c - (shape >> 4)
                kq = compute_rice_k(q)
                kc = compute_rice_k(c)
                write_bits!(bwL,kq,4); rice_encode(bwL,q,kq)
                write_bits!(bwC,kc,4); rice_encode(bwC,c,kc)
                if isL
                    shapeL=newshape
                else
                    shapeR=newshape
                end
            end
        end
    end

    flush_bits!(bwL); flush_bits!(bwC)
    return bwL.data, bwC.data
end

function decode(bsL, bsC, N::Int, ::Type{T}) where T<:Integer
    clamp_fn = x->clamp_sample(x,T)
    lmsL,lmsR = LMS(), LMS()
    Xrec = Vector{Stereo{T}}(undef, N)
    pos=1
    brL,brC = BitReader(bsL), BitReader(bsC)

    while pos <= N
        use_ms = read_bits!(brL,1)!=0
        shiftA,shiftB = Int(read_bits!(brL,4)), Int(read_bits!(brL,4))
        Ns = min(BLOCKSIZE, N-pos+1)
        shapeL,shapeR = Int32(0),Int32(0)  # Reset per block

        for _ in 1:Ns
            vals=Int32[]
            for (shape,shift,isL) in ((shapeL,shiftA,true),(shapeR,shiftB,false))
                kq = Int(read_bits!(brL,4)); q = rice_decode(brL,kq)
                kc = Int(read_bits!(brC,4)); c = rice_decode(brC,kc)
                err_shaped = (q<<shift)+c
                err = err_shaped - shape
                newshape = c - (shape>>4)
                push!(vals,err)
                if isL
                    shapeL=newshape
                else
                    shapeR=newshape
                end
            end

            if use_ms
                mid,side = vals[1], vals[2]
                vals[1] = mid + ((side + (side & 1)) >> 1)  # L
                vals[2] = vals[1] - side                     # R
            end

            resL,resR = vals[1], vals[2]
            L = lms_predict(lmsL)+resL
            R = lms_predict(lmsR)+resR

            Xrec[pos] = Stereo{T}(clamp_fn(L), clamp_fn(R))
            lms_update!(lmsL,resL,L)
            lms_update!(lmsR,resR,R)

            pos += 1
        end
    end
    Xrec
end

# -------------------------
# Test
# -------------------------
function test_codec()
    println("Running SoundCore hybrid test...")

    # 16-bit test
    X16 = [Stereo{Int16}(rand(Int16), rand(Int16)) for _ in 1:5000]
    wv16,wvc16 = encode(X16)
    Xrec16 = decode(wv16,wvc16,5000, Int16)
    println("16-bit:", all(((a,b),)->a==b, zip(X16,Xrec16)) ? "✅" : "❌")

    # 24-bit test
    X24 = [Stereo{Int24}(Int24(rand(UInt32(0):UInt32(16_777_215))-8_388_608),
                        Int24(rand(UInt32(0):UInt32(16_777_215))-8_388_608)) for _ in 1:5000]
    wv24,wvc24 = encode(X24)
    Xrec24 = decode(wv24,wvc24,5000, Int24)
    println("24-bit Int24:", all(((a,b),)->a==b, zip(X24,Xrec24)) ? "✅" : "❌")
end

end

using .WavPackHybrid
WavPackHybrid.test_codec()
