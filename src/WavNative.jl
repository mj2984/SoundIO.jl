#module WavNative

#using ..AudioCore
using BitIntegers, FixedPointNumbers

export WavMetadata, get_wav_layout, audioread

struct WavMetadata{nbits, nchans}
    format_tag::UInt16
    sample_rate::Int
    data_offset::Int64
    data_size::Int64
end

const TransportMapping = Dict{Int, DataType}(8  => UInt8, 16 => Int16, 24 => Int32, 32 => Int32)

const RIFF_ID = (UInt8('R'), UInt8('I'), UInt8('F'), UInt8('F'))
const WAVE_ID = (UInt8('W'), UInt8('A'), UInt8('V'), UInt8('E'))
const FMT_ID  = (UInt8('f'), UInt8('m'), UInt8('t'), UInt8(' '))
const DATA_ID = (UInt8('d'), UInt8('a'), UInt8('t'), UInt8('a'))

function get_wav_layout(data::Vector{UInt8})
    length(data) < 44 && error("File too small to be a WAV")
    (ntuple(i -> data[i], 4) === RIFF_ID && 
     ntuple(i -> data[i+8], 4) === WAVE_ID) || error("Not a RIFF/WAVE file")
    
    fmt_tag, chans, rate, bits, data_offset, data_size = 0, 0, 0, 0, 0, 0
    pos = 13
    
    while pos + 8 <= length(data)
        chunk_id = (data[pos], data[pos+1], data[pos+2], data[pos+3])
        sz = UInt32(data[pos+4]) | (UInt32(data[pos+5]) << 8) | (UInt32(data[pos+6]) << 16) | (UInt32(data[pos+7]) << 24)
        chunk_data = pos + 8
        
        # 3. Process Chunks
        if chunk_id === FMT_ID
            # Manual LE reconstruction for all header fields
            fmt_tag = UInt16(data[chunk_data])   | (UInt16(data[chunk_data+1]) << 8)
            chans   = Int(UInt16(data[chunk_data+2]) | (UInt16(data[chunk_data+3]) << 8))
            rate    = Int(UInt32(data[chunk_data+4]) | (UInt32(data[chunk_data+5]) << 8) | 
                          (UInt32(data[chunk_data+6]) << 16) | (UInt32(data[chunk_data+7]) << 24))
            bits    = Int(UInt16(data[chunk_data+14]) | (UInt16(data[chunk_data+15]) << 8))
            
        elseif chunk_id === DATA_ID
            data_size, data_offset = Int64(sz), chunk_data
            break # We found the data, we can stop parsing
        end
        
        # Move to next chunk (WAV chunks are padded to 2-byte boundaries)
        pos = chunk_data + sz + (sz % 2)
    end
    return WavMetadata{bits, chans}(fmt_tag, rate, data_offset, data_size)
end

function get_wav_layout(path::String) # The File method: Loads a small chunk (1KB is usually plenty) to find the data offset
    header_chunk = open(io -> read(io, 1024), path, "r")
    return get_wav_layout(header_chunk)
end

function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, ::Type{T}) where {nbits, nchans, T} # audioread RAM methods
    TargetType = nchans == 1 ? T : Sample{nchans, T}
    n_frames = meta.data_size ÷ (nchans * (nbits ÷ 8))
    if nbits != 24 && sizeof(T) * 8 == nbits
        ptr = pointer(data) + meta.data_offset - 1
        final_view = unsafe_wrap(Array, reinterpret(Ptr{TargetType}, ptr), n_frames)
        return final_view, meta.sample_rate
    else
        dest = Vector{TargetType}(undef, n_frames)
        _process_bits!(dest, data, meta)
        return dest, meta.sample_rate
    end
end
function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {nbits, nchans} # The Auto-Infer Method
    BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) : nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    return audioread(data, meta, BaseType)
end
audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, native::Bool) where {nbits, nchans} = native ? audioread(data, meta) : audioread(data, meta, TransportMapping[nbits])
function audioread(path::String, ::Type{T}) where T
    data = read(path)
    meta = get_wav_layout(data)
    return audioread(data, meta, T)
end
function audioread(path::String)
    data = read(path)
    meta = get_wav_layout(data)
    return audioread(data, meta)
end
function audioread(path::String, native_output::Bool)
    data = read(path)
    meta = get_wav_layout(data)
    return audioread(data, meta, native_output)
end

# Use unsafe_load for absolute minimum overhead
@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{24}, ::Type{ET}, format_tag) where {ET}
    # Load 3 bytes and pack into UInt32
    u24 = UInt32(unsafe_load(ptr, 1)) | (UInt32(unsafe_load(ptr, 2)) << 8) | (UInt32(unsafe_load(ptr, 3)) << 16)
    s32 = reinterpret(Int32, u24 << 8) 
    
    if ET <: Integer;           return s32 % ET
    elseif ET <: FixedPoint;    return reinterpret(ET, s32)
    elseif ET <: AbstractFloat; return Float32(s32) * (1.0f0 / 2147483648.0f0)
    end
    return s32
end

@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{16}, ::Type{ET}, format_tag) where {ET}
    # Direct 16-bit load (Note: requires Ptr{Int16} cast for speed)
    s16 = unsafe_load(reinterpret(Ptr{Int16}, ptr))
    
    if ET <: AbstractFloat;     return Float32(s16) * (1.0f0 / 32768.0f0)
    elseif ET <: FixedPoint;    return reinterpret(ET, s16)
    end
    return s16 % ET
end

@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{32}, ::Type{ET}, format_tag) where {ET}
    # Direct 32-bit load
    u32 = unsafe_load(reinterpret(Ptr{UInt32}, ptr))
    
    if ET <: AbstractFloat
        if format_tag == 3
            return reinterpret(Float32, u32)
        else
            return Float32(reinterpret(Int32, u32)) * (1.0f0 / 2147483648.0f0)
        end
    end
    return reinterpret(Int32, u32) % ET
end

function _process_bits!(dest::AbstractVector{T}, raw::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {T, nbits, nchans}
    ET = T <: Sample ? eltype(T) : T
    # Pre-calculate offsets and pointers
    # Use GC.@preserve to ensure the raw buffer doesn't move during pointer work
    GC.@preserve raw begin
        # Get raw pointer to the start of the data
        base_ptr = pointer(raw) + meta.data_offset - 1
        
        bytes_per_sample = nbits ÷ 8
        bytes_per_frame  = nchans * bytes_per_sample
        format_tag       = meta.format_tag

        @inbounds for frame_idx in 1:length(dest)
            # Pointer arithmetic is faster than array indexing [pos]
            frame_ptr = base_ptr + (frame_idx - 1) * bytes_per_frame
            
            samples_tuple = ntuple(Val(nchans)) do ch_idx
                sample_ptr = frame_ptr + (ch_idx - 1) * bytes_per_sample
                return _read_pcm_sample(sample_ptr, Val(nbits), ET, format_tag)
            end
            
            dest[frame_idx] = T <: Sample ? T(samples_tuple...) : samples_tuple[1]
        end
    end
    return dest
end


#end
