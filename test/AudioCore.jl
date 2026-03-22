module AudioCore

using BitIntegers, FixedPointNumbers
import Base: +, -, *, /, show, eltype, promote_rule, broadcastable, getproperty

BitIntegers.@define_integers 24

export Q0f7, Q0f15, Q0f23, Q0f31, Int24, UInt24
export Channels, Stereo, Mono, channel_count
export channelview, colorview, rawview

const Q0f7  = Fixed{Int8, 7}
const Q0f15 = Fixed{Int16, 15}
const Q0f23 = Fixed{Int24, 23} 
const Q0f31 = Fixed{Int32, 31}

struct Channels{N, T<:Number}
    data::NTuple{N, T}
end

const Stereo{T} = Channels{2, T}
const Mono{T}   = T

# Vital: Constructor that allows Channels{N, T}(val1, val2...)
(::Type{Channels{N, T}})(args...) where {N, T} = Channels{N, T}(ntuple(i -> T(args[i]), N))

function getproperty(c::Channels{2, T}, s::Symbol) where T
    s === :l && return c.data[1]
    s === :r && return c.data[2]
    return getfield(c, s)
end

eltype(::Type{Channels{N, T}}) where {N, T} = T
# The Trait that was missing
channel_count(::Type{Channels{N, T}}) where {N, T} = N
channel_count(::Type{T}) where {T<:Number} = 1

*(c::Channels{N, T}, f::Real) where {N, T} = Channels{N, T}(map(x -> x * f, c.data))
+(a::Channels{N, T}, b::Channels{N, T}) where {N, T} = Channels{N, T}(map(+, a.data, b.data))
broadcastable(c::Channels) = Ref(c)

promote_rule(::Type{Q0f7}, ::Type{Q0f23}) = Q0f23
promote_rule(::Type{Q0f15}, ::Type{Q0f23}) = Q0f23
promote_rule(::Type{Q0f23}, ::Type{Float32}) = Float32

channelview(A::AbstractVector{Channels{N, T}}) where {N, T} = reinterpret(reshape, T, A)
colorview(::Type{Channels{N, T}}, A::AbstractMatrix{T}) where {N, T} = reinterpret(reshape, Channels{N, T}, A)
rawview(A::AbstractArray{Fixed{T, f}}) where {T, f} = reinterpret(T, A)

show(io::IO, x::Q0f23) = print(io, Float64(x), "Q0f23")
show(io::IO, c::Channels{N, T}) where {N, T} = print(io, N==2 ? "Stereo{$T}" : "Channels{$N,$T}", "(", join(c.data, ", "), ")")
end
