module WavNative

using ..AudioCore
using BitIntegers, FixedPointNumbers

export WavMetadata, get_wav_layout, audioread

struct WavMetadata{nbits, nchans}
    path::String
    format_tag::UInt16
    sample_rate::Int
    data_offset::Int64
    data_size::Int64
end

const TransportMapping = Dict{Int, DataType}(
    8  => UInt8, 16 => Int16, 24 => Int32, 32 => Int32
)

# --- 1. get_wav_layout logic ---

# The RAM method: Parses the byte array directly
function get_wav_layout(data::Vector{UInt8}, path::String="memory")
    # Check Magic Numbers with views to avoid small copies
    (@view(data[1:4]) == b"RIFF" && @view(data[9:12]) == b"WAVE") || error("Not a WAVE file")
    
    fmt_tag, chans, rate, bits, data_offset, data_size = 0, 0, 0, 0, 0, 0
    pos = 13
    
    while pos + 8 <= length(data)
        # Use views for chunk_id and size
        chunk_id = @view(data[pos:pos+3])
        # reinterpret on a view is zero-copy; [1] gets the actual value
        sz = reinterpret(UInt32, @view(data[pos+4:pos+7]))[1]
        chunk_data = pos + 8
        
        if chunk_id == b"fmt "
            # Applying @view to every slice ensures no tiny copies are made
            fmt_tag = reinterpret(UInt16, @view(data[chunk_data:chunk_data+1]))[1]
            chans   = Int(reinterpret(UInt16, @view(data[chunk_data+2:chunk_data+3]))[1])
            rate    = Int(reinterpret(UInt32, @view(data[chunk_data+4:chunk_data+7]))[1])
            bits    = Int(reinterpret(UInt16, @view(data[chunk_data+14:chunk_data+15]))[1])
        elseif chunk_id == b"data"
            data_size, data_offset = Int64(sz), chunk_data
            break 
        end
        # Handle the potential padding byte for odd chunk sizes
        pos = chunk_data + sz + (sz % 2)
    end
    return WavMetadata{bits, chans}(path, fmt_tag, rate, data_offset, data_size)
end


# The File method: Loads a small chunk (1KB is usually plenty) to find the data offset
function get_wav_layout(path::String)
    header_chunk = open(io -> read(io, 1024), path, "r")
    return get_wav_layout(header_chunk, path)
end

# --- 2. audioread RAM methods ---

# The Worker: Decides between Unsafe Wrap and Allocation
function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, ::Type{T}) where {nbits, nchans, T}
    # This check is resolved at COMPILE TIME because nbits is in the Type
    if nbits != 24 && sizeof(T) * 8 == nbits
        # UNSAFE WRAP: Pointer-based view of the RAM buffer
        ptr = pointer(data) + meta.data_offset - 1
        len = meta.data_size ÷ (nbits ÷ 8)
        raw_view = unsafe_wrap(Array, reinterpret(Ptr{T}, ptr), len)
        final_view = nchans == 1 ? raw_view : reinterpret(nchans == 2 ? Stereo{T} : Channels{nchans, T}, raw_view)
        return final_view, meta.sample_rate
    else
        # RE-ALLOCATE: Required for 24-bit or type conversion
        BaseType = T
        FinalType = nchans == 2 ? Stereo{BaseType} : nchans == 1 ? BaseType : Channels{nchans, BaseType}
        n_frames = meta.data_size ÷ (nchans * (nbits ÷ 8))
        dest = Vector{FinalType}(undef, n_frames)
        # Reuse your existing 24-bit/bit-shuffling logic here
        _process_bits!(dest, data, meta)
        return dest, meta.sample_rate
    end
end

# The Auto-Infer Method
function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {nbits, nchans}
    BaseType = meta.format_tag == 3 ? (nbits == 32 ? Float32 : Float64) :
               nbits == 16 ? Q0f15 : (nbits == 24 ? Q0f23 : Q0f31)
    return audioread(data, meta, BaseType)
end

# The Boolean Method (Native vs Transport)
function audioread(data::Vector{UInt8}, meta::WavMetadata{nbits, nchans}, native::Bool) where {nbits, nchans}
    if native
        return audioread(data, meta)
    else
        return audioread(data, meta, TransportMapping[nbits])
    end
end

# --- 3. audioread Path methods (Single RAM storage) ---

function audioread(path::String, ::Type{T}) where T
    data = read(path) # Single RAM store
    meta = get_wav_layout(data, path)
    return audioread(data, meta, T)
end

function audioread(path::String)
    data = read(path) # Single RAM store
    meta = get_wav_layout(data, path)
    return audioread(data, meta)
end

function audioread(path::String, native_output::Bool)
    data = read(path) # Single RAM store
    meta = get_wav_layout(data, path)
    return audioread(data, meta, native_output)
end

# Helper bit-shuffler
function _process_bits!(dest::AbstractVector{T}, raw::Vector{UInt8}, meta::WavMetadata{nbits, nchans}) where {T, nbits, nchans}
    # ET is the base sample type (e.g., Q0f23 or Float32)
    ET = T <: Channels ? eltype(T) : T
    data_start = meta.data_offset
    bytes_per_sample = nbits ÷ 8
    bytes_per_frame = nchans * bytes_per_sample

    @inbounds @simd for i in 1:length(dest)
        frame_offset = data_start + (i - 1) * bytes_per_frame
        
        # This ntuple is zero-cost because nchans is a type parameter
        samples_tuple = ntuple(nchans) do ch
            off = frame_offset + (ch - 1) * bytes_per_sample
            
            # --- 24-bit Path ---
            if nbits == 24
                # Reconstruct 24-bit Little Endian into 32-bit MSB-aligned
                u24 = UInt32(raw[off]) | (UInt32(raw[off+1]) << 8) | (UInt32(raw[off+2]) << 16)
                s32 = reinterpret(Int32, u24 << 8)
                
                if ET <: Integer
                    return s32 % ET
                elseif ET <: FixedPoint
                    return reinterpret(ET, s32)
                elseif ET <: AbstractFloat
                    return Float32(s32) * (1.0f0 / 2147483648.0f0)
                end
                return s32

            # --- 16-bit Path (Used if user requests conversion, e.g., to Float32) ---
            elseif nbits == 16
                u16 = UInt16(raw[off]) | (UInt16(raw[off+1]) << 8)
                s16 = reinterpret(Int16, u16)
                
                if ET <: AbstractFloat
                    return Float32(s16) * (1.0f0 / 32768.0f0)
                elseif ET <: FixedPoint
                    return reinterpret(ET, s16)
                end
                return s16 % ET

            # --- 32-bit Path (Standard Int32 or Float32) ---
            elseif nbits == 32
                # Fast reinterpret read
                val = reinterpret(Int32, raw[off:off+3])[1]
                if ET <: AbstractFloat && meta.format_tag == 3
                    return reinterpret(Float32, val)
                elseif ET <: AbstractFloat
                    return Float32(val) * (1.0f0 / 2147483648.0f0)
                end
                return val % ET
            end
        end
        
        # Pack the tuple into the destination (Stereo, Mono, or Channels)
        dest[i] = T <: Channels ? T(samples_tuple...) : samples_tuple[1]
    end
    return dest
end

end
