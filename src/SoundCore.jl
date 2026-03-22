#module SoundCore

using BitIntegers, FixedPointNumbers
import Base: +, -, *, /, show, eltype, promote_rule, broadcastable, getproperty

BitIntegers.@define_integers 24

export Q0f7, Q0f15, Q0f23, Q0f31, Int24, UInt24
export Sample, Stereo, Mono, channel_count
export channelview, colorview, rawview

# Fixed-point audio types
const Q0f7  = Fixed{Int8, 7}
const Q0f15 = Fixed{Int16, 15}
const Q0f23 = Fixed{Int24, 23} 
const Q0f31 = Fixed{Int32, 31}

"""
    Sample{N, T}
Represents a single point in time across `N` channels of type `T`.
This is the "Pixel" of the audio/signal world.
"""
struct Sample{N, T<:Number}
    data::NTuple{N, T}
end

# Convenience Aliases
const Stereo{T} = Sample{2, T}
const Mono{T}   = T

# Constructor for Sample{N, T}(val1, val2...)
(::Type{Sample{N, T}})(args...) where {N, T} = Sample{N, T}(ntuple(i -> T(args[i]), N))

# Property access for Stereo (e.g., sample.l, sample.r)
function getproperty(c::Sample{2, T}, s::Symbol) where T
    s === :l && return getfield(c, :data)[1]
    s === :r && return getfield(c, :data)[2]
    return getfield(c, s)
end

eltype(::Type{Sample{N, T}}) where {N, T} = T

# Channel Trait
channel_count(::Type{Sample{N, T}}) where {N, T} = N
channel_count(::Type{T}) where {T<:Number} = 1

# Basic Arithmetic
*(c::Sample{N, T}, f::Real) where {N, T} = Sample{N, T}(map(x -> x * f, c.data))
+(a::Sample{N, T}, b::Sample{N, T}) where {N, T} = Sample{N, T}(map(+, a.data, b.data))

# Broadcasting (treat Sample as a single scalar unit)
broadcastable(c::Sample) = Ref(c)

# Promotion Rules
promote_rule(::Type{Q0f7}, ::Type{Q0f23}) = Q0f23
promote_rule(::Type{Q0f15}, ::Type{Q0f23}) = Q0f23
promote_rule(::Type{Q0f23}, ::Type{Float32}) = Float32

# Memory Views (Zero-copy reinterpretation)
channelview(A::AbstractVector{Sample{N, T}}) where {N, T} = reinterpret(reshape, T, A)
colorview(::Type{Sample{N, T}}, A::AbstractMatrix{T}) where {N, T} = reinterpret(reshape, Sample{N, T}, A)
rawview(A::AbstractArray{Fixed{T, f}}) where {T, f} = reinterpret(T, A)

# Formatting
show(io::IO, x::Q0f23) = print(io, Float64(x), "Q0f23")
show(io::IO, c::Sample{N, T}) where {N, T} = print(io, N==2 ? "Stereo{$T}" : "Sample{$N,$T}", "(", join(c.data, ", "), ")")

#end
#=
Other Data Types: This is perfect for:
Inertial Sensors (IMU): A 3-axis accelerometer output (x,y,z).
Financial Data: OHLC (Open, High, Low, Close) price bars.
Robotics: Joint positions or force-torque sensor vectors.
=#
