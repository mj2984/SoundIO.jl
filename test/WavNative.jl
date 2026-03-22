module WavNative

using ..AudioCore
using BitIntegers, FixedPointNumbers

export WavMetadata,get_wav_layout, audioread, audioread!

struct WavMetadata
    path::String
    format_tag::UInt16
    nchannels::Int
    sample_rate::Int
    nbits::Int
    data_offset::Int64
    data_size::Int64
end

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
        return WavMetadata(path, fmt_tag, chans, rate, bits, data_offset, data_size)
    end
end

# Inside AudioCore or WavNative
bit_depth(::Type{T}) where {T<:Number} = sizeof(T) * 8
bit_depth(::Type{Fixed{T, f}}) where {T, f} = sizeof(T) * 8
bit_depth(::Type{Channels{N, T}}) where {N, T} = bit_depth(T)
function audioread!(dest::AbstractVector{T}, meta::WavMetadata) where T
    ET = T <: Channels ? eltype(T) : T
    nchans = meta.nchannels
    
    open(meta.path, "r") do io
        seek(io, meta.data_offset)

        if meta.nbits == 24
            # Buffer for one "frame" (all channels) to minimize I/O calls
            frame_bytes = Vector{UInt8}(undef, nchans * 3)
            
            for i in 1:length(dest)
                # Read exactly one frame's worth of bytes
                read!(io, frame_bytes)
                
                # Use a simple for-loop for channels instead of ntuple
                # The compiler will "unroll" this for Mono/Stereo
                samples_tuple = ntuple(nchans) do ch
                    offset = (ch - 1) * 3
                    u24 = UInt32(frame_bytes[offset + 1]) | 
                          (UInt32(frame_bytes[offset + 2]) << 8) | 
                          (UInt32(frame_bytes[offset + 3]) << 16)
                    
                    s32_left = reinterpret(Int32, u24 << 8)

                    # Branching on types is free because ET is a compile-time constant
                    if ET <: Integer
                        return s32_left % ET
                    elseif ET <: FixedPoint
                        return reinterpret(ET, s32_left)
                    elseif ET <: AbstractFloat
                        return Float32(s32_left) / 2147483648.0f0
                    else
                        return s32_left
                    end
                end
                
                @inbounds dest[i] = T <: Channels ? T(samples_tuple...) : samples_tuple[1]
            end
        else
            # Standard 8, 16, 32-bit paths use Julia's highly optimized read!
            read!(io, dest)
        end
    end
    return dest
end

function audioread(meta::WavMetadata, ::Type{T}=Any) where T
    BaseType = T !== Any ? T : 
               meta.format_tag == 3 ? (meta.nbits == 32 ? Float32 : Float64) :
               meta.nbits == 16 ? Q0f15 : (meta.nbits == 24 ? Q0f23 : Q0f31)
    FinalType = meta.nchannels == 2 ? Stereo{BaseType} : 
                meta.nchannels == 1 ? BaseType : Channels{meta.nchannels, BaseType}
    n_frames = meta.data_size ÷ (meta.nchannels * (meta.nbits ÷ 8))
    dest = Vector{FinalType}(undef, n_frames)
    audioread!(dest, meta)
    return dest,meta.sample_rate
end
function audioread(path::String, ::Type{T}=Any) where T
    meta = get_wav_layout(path)
    audioread(meta,T)
end
function audioread(path::String; native_output::Bool=true)
    meta = get_wav_layout(path)
    if native_output
        return audioread(meta, Any)
    else
        T = TransportMapping[meta.nbits]
        return audioread(meta, T)
    end
end
end
