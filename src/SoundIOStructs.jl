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
# Internal C-struct for safe pointer access
struct SoundIoDevice_C
    soundio::Ptr{Cvoid}
    id::Ptr{Cchar}
    name::Ptr{Cchar}
    # ... other fields ignored as we access via struct padding
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
struct SoundIOOutStream
    ptr::Ptr{SoundIoOutStream_C}
    format::Cint #Int32
    rate::Cint #Int32
end
struct SoundIODevice
    ptr::Ptr{Cvoid}
    name::String
    id::String
    is_input::Bool
    is_default::Bool
    streams::Vector{SoundIOOutStream}
    function SoundIODevice(ptr::Ptr{Cvoid}, name::String, id::String, is_input::Bool, is_default::Bool)
        # Increment Ref Count: Tell C we are holding this memory
        ccall((:soundio_device_ref, libsoundio), Cvoid, (Ptr{Cvoid},), ptr)
        dev = new(ptr, name, id, is_input, is_default, SoundIOOutStream[])
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
end
struct SoundIOContext
    ptr::Ref{Ptr{Cvoid}}
    devices::Vector{SoundIODevice}
    function SoundIOContext()
        p = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
        p == C_NULL && error("Failed to create SoundIO context")
        return new(Ref(p), SoundIODevice[])
    end
end
#=
mutable struct SoundIORingBuffer
    ptr::Ptr{Cvoid}
end
=#
# --- Playback Logic ---
struct FrozenAudioLayout # The "Map": Immutable description of the static memory
    data_ptr::Ptr{Int32}
    total_frames::Int64
    channels::Int32
end
# The "Engine": Mutable state for the active playback
mutable struct FrozenAudioStream
    current_frame::Int64
    is_playing::Bool
    is_finished::Bool
    _areas_ref::Ref{Ptr{SoundIoChannelArea_C}} # Pre-allocated to avoid GC churn in the high-speed callback
    _frames_ref::Ref{Cint}
end
# The "Container": The single object we track in Julia
mutable struct FrozenAudioBuffer
    layout::FrozenAudioLayout
    stream::FrozenAudioStream
    function FrozenAudioBuffer(ptr::Ptr{Int32}, frames::Integer, channels::Integer)
        layout = FrozenAudioLayout(ptr, Int64(frames), Int32(channels))
        stream = FrozenAudioStream(0, true, false, Ref{Ptr{SoundIoChannelArea_C}}(), Ref{Cint}(0))
        return new(layout, stream)
    end
end
#=
struct PlaybackTargets
    data_ptr::Ptr{Int32}
    total_frames::Int64
end
=#
