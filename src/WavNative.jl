#module WavNative

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

get_nbits(::WavMetadata{B, C}) where {B, C} = B
get_nchans(::WavMetadata{B, C}) where {B, C} = C

"""
    malloc_read(path)
Allocates file buffer on the C-heap to reduce Julia GC pressure.
"""
function malloc_read(path::String)
    sz = filesize(path)
    ptr = Libc.malloc(sz)
    ptr == C_NULL && throw(OutOfMemoryError())
    try
        open(path, "r") do io
            unsafe_read(io, ptr, sz)
        end
    catch e
        Libc.free(ptr)
        rethrow(e)
    end
    # Wrap in Vector for parsing; own=false because we handle free() manually
    return unsafe_wrap(Vector{UInt8}, convert(Ptr{UInt8}, ptr), sz; own=false), ptr
end

function get_wav_layout(data::AbstractVector{UInt8})
    length(data) < 44 && error("File too small to be a WAV")
    (ntuple(i -> data[i], 4) === RIFF_ID && 
     ntuple(i -> data[i+8], 4) === WAVE_ID) || error("Not a RIFF/WAVE file")
    
    fmt_tag, chans, rate, bits, data_offset, data_size = 0, 0, 0, 0, 0, 0
    pos = 13
    while pos + 8 <= length(data)
        chunk_id = (data[pos], data[pos+1], data[pos+2], data[pos+3])
        sz = UInt32(data[pos+4]) | (UInt32(data[pos+5]) << 8) | (UInt32(data[pos+6]) << 16) | (UInt32(data[pos+7]) << 24)
        chunk_data = pos + 8
        if chunk_id === FMT_ID
            fmt_tag = UInt16(data[chunk_data])   | (UInt16(data[chunk_data+1]) << 8)
            chans   = Int(UInt16(data[chunk_data+2]) | (UInt16(data[chunk_data+3]) << 8))
            rate    = Int(UInt32(data[chunk_data+4]) | (UInt32(data[chunk_data+5]) << 8) | (UInt32(data[chunk_data+6]) << 16) | (UInt32(data[chunk_data+7]) << 24))
            bits    = Int(UInt16(data[chunk_data+14]) | (UInt16(data[chunk_data+15]) << 8))
        elseif chunk_id === DATA_ID
            data_size, data_offset = Int64(sz), chunk_data
            break 
        end
        pos = chunk_data + sz + (sz % 2)
    end
    return WavMetadata{bits, chans}(fmt_tag, rate, data_offset, data_size)
end

function get_wav_layout(path::String)
    header_chunk = open(io -> read(io, 1024), path, "r")
    return get_wav_layout(header_chunk)
end

function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, ::Type{T}, raw_ptr::Ptr{Cvoid}=C_NULL) where {nbits, nchans, T}
    TargetType = nchans == 1 ? T : Sample{nchans, T}
    n_frames = meta.data_size ÷ (nchans * (nbits ÷ 8))

    if nbits != 24 && sizeof(T) * 8 == nbits # FAST PATH: Zero-copy view
        audio_ptr = convert(Ptr{UInt8}, raw_ptr) + meta.data_offset - 1
        final_view = unsafe_wrap(Array, reinterpret(Ptr{TargetType}, audio_ptr), n_frames)
        if raw_ptr != C_NULL# If we have a raw_ptr, tell Julia to own the original base allocation for cleanup
            _ = unsafe_wrap(Vector{UInt8}, convert(Ptr{UInt8}, raw_ptr), meta.data_offset + meta.data_size; own=true)
        end
        return final_view, meta.sample_rate
    else # PROCESS PATH: Copy/Convert to new Julia Vector
        dest = Vector{TargetType}(undef, n_frames)
        _process_bits!(dest, data, meta)
        raw_ptr != C_NULL && Libc.free(raw_ptr) # Clear manual allocation if it exists
        return dest, meta.sample_rate
    end
end
function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {nbits, nchans} # Interface methods for RAM-based Vector{UInt8}
    BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) : nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    return audioread(data, meta, BaseType)
end
audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, native::Bool) where {nbits, nchans} = native ? audioread(data, meta) : audioread(data, meta, TransportMapping[nbits])
function audioread(path::String, ::Type{T}) where T # Interface methods for file paths (Main entry points)
    raw_vec, raw_ptr = malloc_read(path)
    meta = get_wav_layout(raw_vec)
    return audioread(raw_vec, meta, T, raw_ptr)
end
function audioread(path::String)
    raw_vec, raw_ptr = malloc_read(path)
    meta = get_wav_layout(raw_vec)
    nbits = get_nbits(meta)
    BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) : nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    return audioread(raw_vec, meta, BaseType, raw_ptr)
end

function audioread(path::String, native_output::Bool)
    raw_vec, raw_ptr = malloc_read(path)
    meta = get_wav_layout(raw_vec)
    nbits = get_nbits(meta)
    if native_output
        BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) : nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    else
        BaseType = TransportMapping[nbits]
    end
    return audioread(raw_vec, meta, BaseType, raw_ptr)
end

# Optimized Scalar Readers
@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{24}, ::Type{ET}, format_tag) where {ET}
    u24 = UInt32(unsafe_load(ptr, 1)) | (UInt32(unsafe_load(ptr, 2)) << 8) | (UInt32(unsafe_load(ptr, 3)) << 16)
    s32 = reinterpret(Int32, u24 << 8) 
    if ET <: Integer;           return s32 % ET
    elseif ET <: FixedPoint;    return reinterpret(ET, s32)
    elseif ET <: AbstractFloat; return Float32(s32) * (1.0f0 / 2147483648.0f0)
    end
    return s32
end
@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{16}, ::Type{ET}, format_tag) where {ET}
    s16 = unsafe_load(reinterpret(Ptr{Int16}, ptr))
    if ET <: AbstractFloat;     return Float32(s16) * (1.0f0 / 32768.0f0)
    elseif ET <: FixedPoint;    return reinterpret(ET, s16)
    end
    return s16 % ET
end
@inline function _read_pcm_sample(ptr::Ptr{UInt8}, ::Val{32}, ::Type{ET}, format_tag) where {ET}
    u32 = unsafe_load(reinterpret(Ptr{UInt32}, ptr))
    if ET <: AbstractFloat
        return format_tag == 3 ? reinterpret(Float32, u32) : Float32(reinterpret(Int32, u32)) * (1.0f0 / 2147483648.0f0)
    end
    return reinterpret(Int32, u32) % ET
end

# Vectorized Loop
function _process_bits!(dest::AbstractVector{T}, raw::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {T, nbits, nchans}
    ET = T <: Sample ? eltype(T) : T
    GC.@preserve raw begin
        base_ptr = pointer(raw) + meta.data_offset - 1
        bps, bpf = nbits ÷ 8, nchans * (nbits ÷ 8)
        f_tag = meta.format_tag
        @inbounds for frame_idx in 1:length(dest)
            frame_ptr = base_ptr + (frame_idx - 1) * bpf
            samples_tuple = ntuple(Val(nchans)) do ch_idx
                sample_ptr = frame_ptr + (ch_idx - 1) * bps
                return _read_pcm_sample(sample_ptr, Val(nbits), ET, f_tag)
            end
            dest[frame_idx] = T <: Sample ? T(samples_tuple...) : samples_tuple[1]
        end
    end
    return dest
end

#end
