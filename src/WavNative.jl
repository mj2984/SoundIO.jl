module WavNative
using ..SamplesCore
using BitIntegers, FixedPointNumbers#SoundCore

export WavMetadata, get_wav_layout, audioread

struct WavMetadata{Bits, Channels}
    format_tag::UInt16
    sample_rate::Int
    data_offset::Int64
    data_size::Int64
end

const TransportMapping = Dict{Int, DataType}(8 => UInt8, 16 => Int16, 24 => Int32, 32 => Int32)
const WavMemoryInput = Union{Vector{UInt8},Tuple{Vector{UInt8},Ptr{Cvoid}}}

const RIFF_ID = (UInt8('R'), UInt8('I'), UInt8('F'), UInt8('F'))
const WAVE_ID = (UInt8('W'), UInt8('A'), UInt8('V'), UInt8('E'))
const FMT_ID  = (UInt8('f'), UInt8('m'), UInt8('t'), UInt8(' '))
const DATA_ID = (UInt8('d'), UInt8('a'), UInt8('t'), UInt8('a'))

get_nbits(::WavMetadata{Bits, Channels}) where {Bits, Channels} = Bits
get_nchans(::WavMetadata{Bits, Channels}) where {Bits, Channels} = Channels
get_base_type(meta::WavMetadata{Bits, Channels}) where {Bits, Channels} = meta.format_tag == 3 ? (Bits == 32 ? Float32 : Float64) : Bits == 16 ? Q0f15 : (Bits == 24 ? Q0f23 : Q0f31)

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
    return unsafe_wrap(Vector{UInt8}, convert(Ptr{UInt8}, ptr), sz; own=false), ptr
end

function get_layout_wav(data::AbstractVector{UInt8})
    length(data) < 44 && error("File too small to be a WAV")
    (ntuple(i -> data[i], 4) === RIFF_ID && ntuple(i -> data[i+8], 4) === WAVE_ID) || error("Not a RIFF/WAVE file")
    
    fmt_tag::UInt16, Channels::UInt16, rate::UInt32, Bits::UInt16, data_offset::Int64, data_size::Int64 = 0, 0, 0, 0, 0, 0
    pos::Int = 13
    while pos + 8 <= length(data)
        chunk_id = (data[pos], data[pos+1], data[pos+2], data[pos+3])
        sz = UInt32(data[pos+4]) | (UInt32(data[pos+5]) << 8) | (UInt32(data[pos+6]) << 16) | (UInt32(data[pos+7]) << 24)
        chunk_data = pos + 8
        if chunk_id === FMT_ID
            fmt_tag  = UInt16(data[chunk_data]) | (UInt16(data[chunk_data+1]) << 8)
            Channels = (UInt16(data[chunk_data+2]) | (UInt16(data[chunk_data+3]) << 8))
            rate     = (UInt32(data[chunk_data+4]) | (UInt32(data[chunk_data+5]) << 8) | (UInt32(data[chunk_data+6]) << 16) | (UInt32(data[chunk_data+7]) << 24))
            Bits     = (UInt16(data[chunk_data+14]) | (UInt16(data[chunk_data+15]) << 8))
        elseif chunk_id === DATA_ID
            data_size, data_offset = Int64(sz), chunk_data
            break 
        end
        pos = chunk_data + sz + (sz % 2)
    end
    return WavMetadata{Int(Bits), Int(Channels)}(fmt_tag, Int(rate), data_offset, data_size)
end

function get_layout_wav(path::String)
    header_chunk = open(io -> read(io, 1024), path, "r")
    return get_layout_wav(header_chunk)
end

function base_wav_parser(Input::WavMemoryInput, meta::WavMetadata{Bits, Channels}, ::Type{T}) where {Bits, Channels, T}
    data, raw_ptr, ismalloc = if Input isa Tuple
        Input[1], Input[2], true
    else
        Input, pointer(Input), false
    end
    TargetType = Channels == 1 ? T : Sample{Channels, T}
    n_frames = meta.data_size ÷ (Channels * (Bits ÷ 8))

    if Bits != 24 && sizeof(T) * 8 == Bits # FAST PATH: Zero-copy
        audio_ptr = convert(Ptr{UInt8}, raw_ptr) + (meta.data_offset - 1)
        final_view = unsafe_wrap(Array, reinterpret(Ptr{TargetType}, audio_ptr), n_frames)
        if ismalloc
            finalizer(x -> Libc.free(raw_ptr), final_view)
        end
        return final_view, meta.sample_rate
    else # PROCESS PATH: Copy/Convert
        dest = Vector{TargetType}(undef, n_frames)
        _process_bits!(dest, data, meta)
        if ismalloc
            Libc.free(raw_ptr) 
        end
        return dest, meta.sample_rate
    end
end

audioread(Input::WavMemoryInput, meta::WavMetadata, parser_function::F = base_wav_parser) where {F<:Function} = parser_function(Input, meta, get_base_type(meta))
audioread(Input::WavMemoryInput, meta::WavMetadata{Bits, Channels}, native_output::Bool, parser_function::F = base_wav_parser) where {Bits, Channels, F<:Function} = native_output ? audioread(Input, meta) : parser_function(Input, meta, TransportMapping[Bits])
function audioread(path::String, output_param::Union{Bool, Type} = false, parser_function::F = base_wav_parser) where {F<:Function}
    raw_vec, raw_ptr = malloc_read(path)
    meta = get_layout_wav(raw_vec)
    if output_param isa Bool
        return audioread((raw_vec, raw_ptr), meta, output_param, parser_function)
    else
        return parser_function((raw_vec, raw_ptr), meta, output_param)
    end
end

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
end
