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

function get_wav_layout(io::IO, path::String)
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
    return WavMetadata{bits, chans}(path, fmt_tag, rate, data_offset, data_size)
end
function get_wav_layout(path::String)
    open(path, "r") do io
        get_wav_layout(io, path)
    end
end

function audioread!(dest::AbstractVector{T}, io::IO, meta::WavMetadata{nbits, nchans}) where {T, nbits, nchans}
    ET = T <: Channels ? eltype(T) : T
    seek(io, meta.data_offset)
    if nbits == 24
        raw_bytes = Vector{UInt8}(undef, meta.data_size)
        read!(io, raw_bytes)
        
        bytes_per_frame = nchans * 3
        @inbounds @simd for i in 1:length(dest)
            frame_offset = (i - 1) * bytes_per_frame
            samples_tuple = ntuple(nchans) do ch
                offset = frame_offset + (ch - 1) * 3
                u24 = UInt32(raw_bytes[offset + 1])        | 
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
            dest[i] = T <: Channels ? T(samples_tuple...) : samples_tuple[1]
        end
    else
        read!(io, dest)
    end
    return dest
end

function audioread!(dest::AbstractVector{T}, meta::WavMetadata{nbits, nchans}) where {T, nbits, nchans}
    open(meta.path, "r") do io
        audioread!(dest, io, meta)
    end
    return dest
end

function audioread(io::IO, meta::WavMetadata{nbits, nchans}, ::Type{T}) where {nbits, nchans, T}
    FinalType = nchans == 2 ? Stereo{T} : 
                nchans == 1 ? T : Channels{nchans, T}
    
    n_frames = meta.data_size ÷ (nchans * (nbits ÷ 8))
    dest = Vector{FinalType}(undef, n_frames)
    audioread!(dest, io, meta)
    return dest, meta.sample_rate
end

function audioread(io::IO, meta::WavMetadata{nbits, nchans}) where {nbits, nchans}
    BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) :
               nbits == 16 ? Q0f15 : 
               nbits == 24 ? Q0f23 : Q0f31
               
    return audioread(io, meta, BaseType)
end

function audioread(meta::WavMetadata{nbits, nchans}, ::Type{T}) where {T, nbits, nchans}
    open(meta.path, "r") do io
        audioread(io, meta, T)
    end
end

function audioread(path::String, ::Type{T}) where T
    open(path, "r") do io
        meta = get_wav_layout(io, path)
        return audioread(io, meta, T)
    end
end

function audioread(path::String)
    open(path, "r") do io
        meta = get_wav_layout(io, path)
        return audioread(io, meta)
    end
end

function audioread(io::IO, meta::WavMetadata{nbits, nchans}, native_output::Bool) where {nbits, nchans}
    if native_output
        return audioread(io, meta, Any)
    else
        T = TransportMapping[nbits]
        return audioread(io, meta, T)
    end
end

function audioread(path::String, native_output::Bool)
    open(path, "r") do io
        meta = get_wav_layout(io, path)
        audioread(io,meta,native_output)
    end
end
end
#=
function align_audio_bytes!(data,source_bits::T,destination_format::Symbol) where {T<:Integer}
    if(source_bits == 24 && destination_format == :Int32Little)
        map!(x -> x << 8, data,data)
    elseif(source_bits == 16 && destination_format == :Int32Little)
        map!(x -> x << 16, data,data)
    end
end
@inline function process_audio(path)
    audio_data,sample_rate, nbits, opt = wavread(path, format = "native", raw_layout = true)
    if(nbits > 16)
        destination_format = :Int32Little
        align_audio_bytes!(audio_data,nbits,destination_format)
        map!(x -> x>> 16, audio_data, audio_data)
    else
        destination_format = :Int16Little
    end
    return Int16.(audio_data), sample_rate, :Int16Little#destination_format
end
=#
