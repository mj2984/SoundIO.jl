module WavNative

using ..AudioCore
using BitIntegers, FixedPointNumbers

export WavMetadata,get_wav_layout, audioread, audioread!

struct WavMetadata{nbits,nchans}
    path::String
    format_tag::UInt16
    sample_rate::Int
    data_offset::Int64
    data_size::Int64
end

bit_depth(::Type{T}) where {T<:Number} = sizeof(T) * 8
bit_depth(::Type{Fixed{T, f}}) where {T, f} = sizeof(T) * 8
bit_depth(::Type{Channels{N, T}}) where {N, T} = bit_depth(T)

const TransportMapping = Dict{Int, DataType}(
    8  => UInt8,
    16 => Int16,
    24 => Int32, # 24 is "promoted" to 32 for CPU/Pointer safety
    32 => Int32
)

function get_wav_layout(path::String)
    open(path, "r") do io
        read(io, 4) == b"RIFF" || error("Not a RIFF file")
        skip(io, 4); read(io, 4) == b"WAVE" || error("Not a WAVE file")
        fmt_tag, chans, rate, bits, data_offset, data_size = 0, 0, 0, 0, 0, 0
        while !eof(io)
            chunk_id = read(io, 4)
            sz = read(io, UInt32)
            curr = position(io)
            if chunk_id == b"fmt "
                fmt_tag = read(io, UInt16)
                chans = Int(read(io, UInt16)); rate = Int(read(io, UInt32))
                skip(io, 6); bits = Int(read(io, UInt16))
            elseif chunk_id == b"data"
                data_size, data_offset = Int64(sz), curr
                break 
            end
            seek(io, curr + sz + (sz % 2))
        end
        return WavMetadata{bits,chans}(path, fmt_tag, rate, data_offset, data_size)
    end
end

function audioread!(dest::AbstractVector{T}, meta::WavMetadata{nbits,nchans}) where {T,nbits,nchans}
    ET = T <: Channels ? eltype(T) : T
    open(meta.path, "r") do io
        seek(io, meta.data_offset)
        if nbits == 24
            raw_bytes = Vector{UInt8}(undef, meta.data_size)
            read!(io, raw_bytes)
            bytes_per_frame = nchans * 3
            @simd for i in 1:length(dest)
                frame_offset = (i - 1) * bytes_per_frame
                samples_tuple = ntuple(nchans) do ch
                    offset = frame_offset + (ch - 1) * 3
                    @inbounds u24 = UInt32(raw_bytes[offset + 1])        | 
                                    (UInt32(raw_bytes[offset + 2]) << 8) | 
                                    (UInt32(raw_bytes[offset + 3]) << 16)
                    
                    s32_aligned = reinterpret(Int32, u24 << 8)
                    if ET <: Integer
                        return s32_aligned % ET
                    elseif ET <: FixedPoint
                        return reinterpret(ET, s32_aligned)
                    elseif ET <: AbstractFloat
                        return Float32(s32_aligned) * (1.0f0 / 2147483648.0f0)
                    end
                    return s32_aligned
                end
                @inbounds dest[i] = T <: Channels ? T(samples_tuple...) : samples_tuple[1]
            end
        else
            read!(io, dest)
        end
    end
    return dest
end

function audioread(meta::WavMetadata{nbits,nchans}, ::Type{T}=Any) where {T,nbits,nchans}
    BaseType = T !== Any ? T : 
               meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) :
               nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    FinalType = nchans == 2 ? Stereo{BaseType} : 
                nchans == 1 ? BaseType : Channels{nchans, BaseType}
    n_frames = meta.data_size ÷ (nchans * (nbits ÷ 8))
    dest = Vector{FinalType}(undef, n_frames)
    audioread!(dest, meta)
    return dest,meta.sample_rate
end
function audioread(path::String, ::Type{T}=Any) where T
    meta = get_wav_layout(path)
    audioread(meta,T)
end
function audioread(meta::WavMetadata{nbits,nchans}, native_output::Bool) where {nbits,nchans} 
    audioread(meta, TransportMapping[nbits])
end
function audioread(path::String; native_output::Bool=true)
    meta = get_wav_layout(path)
    if native_output
        return audioread(meta, Any)
    else
        return audioread(meta, native_output)
    end
end
end
