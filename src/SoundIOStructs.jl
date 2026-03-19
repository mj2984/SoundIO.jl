# Low-Level C-Compatible Structs (Matching libsoundio headers)
struct SoundIoChannelArea_C
    ptr::Ptr{UInt8}
    step::Cint
end
struct SoundIoChannelLayout
    name::Ptr{Cchar}
    channel_count::Cint #Int32
    channels::NTuple{24, Cint} #NTuple{24, Int32}
end
#=
mutable struct SoundIORingBuffer
    ptr::Ptr{Cvoid}
end
=#
# --- Playback Logic ---
struct FrozenAudioLayout{T,total_atoms} # The "Map": Immutable description of the static memory
    data_ptr::Ptr{T}
    atom_frames::Int
    FrozenAudioLayout(data_ptr::Ptr{T},atom_frames::Int,total_atoms::Int) where {T} = new{T,total_atoms}(data_ptr,atom_frames)
end
mutable struct FrozenAudioStream # The "Engine": Mutable state for the active playback
    atomic_frame_offset::Int
    current_offset_base::Int
    @atomic elapsed_frames::Int # A synchronized view that only provides updates atomically at atom boundary crossing.
    @atomic status::Int8 # either 2 or -1 as Julia is always done. # TODO: Make the status atomic.
    notify_handle::Base.AsyncCondition
    FrozenAudioStream() = new(0, 0, 0, CallbackStopped, Base.AsyncCondition())
end
abstract type SoundIOSynchronizer end
struct FrozenAudioBuffer{T,Channels,total_atoms} <: SoundIOSynchronizer # The "Container": The single object we track in Julia
    layout::FrozenAudioLayout{T}
    stream::FrozenAudioStream
    function FrozenAudioBuffer(ptr::Ptr{T}, atom_frames::Integer, total_atoms::Integer, Channels::Integer) where {T}
        layout = FrozenAudioLayout(ptr, Int(atom_frames),Int(total_atoms))
        stream = FrozenAudioStream()
        return new{T,Channels,total_atoms}(layout, stream)
    end
end
struct AudioCallbackMessage
    status::Int8
    data_ptr::Ptr{Cvoid} # Raw hardware address
    actual_frames::Int # Negotiated frame count
end
mutable struct AudioCallbackSynchronizer{T,Channels} <: SoundIOSynchronizer
    @atomic message::AudioCallbackMessage
    notify_handle::Base.AsyncCondition
    AudioCallbackSynchronizer(T, Channels::Integer) = new{T, Channels}(AudioCallbackMessage(CallbackStopped, C_NULL, 0),Base.AsyncCondition())
end
# Internal C-struct for safe pointer access
struct SoundIoDevice_C
    soundio::Ptr{Cvoid}  # Offset 0
    id::Ptr{Cchar}       # Offset 8
    name::Ptr{Cchar}     # Offset 16
    aim::Cint            # Offset 24 (1=Input, 2=Output)
    # ... other fields ignored as we access via struct padding
    #=
    layout_count::Cint       # 28
    layouts::Ptr{Cvoid}      # 32
    current_layout::SoundIoChannelLayout # 40 (Size: ~104 bytes)
    format_count::Cint       # 144
    formats::Ptr{Cint}       # 152
    current_format::Cint     # 160
    sample_rate_count::Cint  # 164
    sample_rates::Ptr{Cvoid} # 168
    sample_rate_current::Cint # 176
    software_latency_min::Cdouble # 184
    software_latency_max::Cdouble # 192
    software_latency_current::Cdouble # 200
    is_raw::UInt8            # 208
    ref_count::Cint          # 212
    =#
end
mutable struct SoundIoOutStream_C
    device::Ptr{Cvoid}
    format::Cint #Int32
    sample_rate::Cint #Int32
    layout::SoundIoChannelLayout
    software_latency::Cdouble #Float64
    volume::Cfloat #Float32
    userdata::Ptr{Cvoid}
    write_callback::Ptr{Cvoid}
    underflow_callback::Ptr{Cvoid}
    error_callback::Ptr{Cvoid}
    name::Ptr{Cchar}
    non_terminal_hint::Cint #Int32
    bytes_per_frame::Cint
    bytes_per_sample::Cint
    layout_error::Cint
end
const SOUNDIO_OUTSTREAM_USERDATA_OFFSET = fieldoffset(SoundIoOutStream_C, 7)
# --- High-Level Julia Wrappers ---
# Pre-declare for the Device struct
struct SoundIOOutStream{T <: SoundIOSynchronizer}
    ptr::Ptr{SoundIoOutStream_C}
    format::Cint #Int32
    rate::Cint #Int32
    sync::Ref{T}
    callback_ptr::Base.CFunction
end
struct SoundIODevicePtrs
    device::Ptr{Cvoid}
    ctx::Ptr{Cvoid}
end
struct SoundIODevice
    ptrs::Base.RefValue{SoundIODevicePtrs}
    name::String
    id::String
    is_input::Bool
    is_default::Bool
    is_raw::Bool
    streams::Vector{SoundIOOutStream}
    function SoundIODevice(ctx_ptr::Ptr{Cvoid}, device_ptr::Ptr{Cvoid}, name::String, id::String, is_input::Bool, is_default::Bool, is_raw::Bool)
        ccall((:soundio_device_ref, libsoundio), Cvoid, (Ptr{Cvoid},), device_ptr) # Increment C-ref count to keep memory alive while this Julia object exists
        return new(Ref(SoundIODevicePtrs(device_ptr, ctx_ptr)), name, id, is_input, is_default, is_raw, SoundIOOutStream[])
        # Decrement Ref Count on GC
        #=finalizer(dev) do d
            for s in d.streams
                ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), s.ptr)
            end
            ccall((:soundio_device_unref, libsoundio), Cvoid, (Ptr{Cvoid},), d.ptr)
        end
        return dev
        =#
    end
    function SoundIODevice(ctx_ptr::Ptr{Cvoid}, device_ptr::Ptr{Cvoid}, is_default::Bool)
        c_dev = unsafe_load(convert(Ptr{SoundIoDevice_C}, device_ptr))
        name_str = unsafe_string(c_dev.name)
        id_str   = unsafe_string(c_dev.id)
        is_input = c_dev.aim == 0
        is_raw = unsafe_load(convert(Ptr{UInt8}, device_ptr + SOUNDIO_DEVICE_IS_RAW_OFFSET)) == 0
        return SoundIODevice(ctx_ptr, device_ptr, name_str, id_str, is_input, is_default, is_raw)
    end
end
struct SoundIOContext
    ptr::Base.RefValue{Ptr{Cvoid}}
    devices::Vector{SoundIODevice}
    function SoundIOContext()
        p = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
        p == C_NULL && error("Failed to create SoundIO context")
        return new(Ref(p), SoundIODevice[])
    end
end
