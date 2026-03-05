# Low-Level C-Compatible Structs
struct SoundIoChannelArea_C
    ptr::Ptr{UInt8}
    step::Cint
end
struct SoundIoChannelLayout
    name::Ptr{Cchar}
    channel_count::Cint
    channels::NTuple{24, Cint}
end
#=
struct SoundIoChannelLayout
    name::Ptr{Cchar}
    channel_count::Int32
    channels::NTuple{24, Int32}
end
=#
mutable struct SoundIoOutStream_C
    device::Ptr{Cvoid}
    format::Cint
    sample_rate::Cint
    layout::SoundIoChannelLayout
    software_latency::Cdouble
    volume::Cfloat
    userdata::Ptr{Cvoid}
    write_callback::Ptr{Cvoid}
    underflow_callback::Ptr{Cvoid}
    error_callback::Ptr{Cvoid}
    name::Ptr{Cchar}
    non_terminal_hint::Cint
    bytes_per_frame::Cint
    bytes_per_sample::Cint
    layout_error::Cint
end
#=
mutable struct SoundIoOutStream_C
    device::Ptr{Cvoid}
    format::Int32
    sample_rate::Int32
    layout::SoundIoChannelLayout
    software_latency::Float64
    volume::Float32
    userdata::Ptr{Cvoid}
    write_callback::Ptr{Cvoid}
    underflow_callback::Ptr{Cvoid}
    error_callback::Ptr{Cvoid}
    name::Ptr{Cchar}
    non_terminal_error::Int32
end
=#
# High-Level Julia Wrappers
struct SoundIODevice
    ptr::Ptr{Cvoid}
    name::String
    is_input::Bool
    is_default::Bool
end
struct SoundIOOutStream
    ptr::Ptr{SoundIoOutStream_C}
    device::SoundIODevice
    format::Cint
    rate::Cint
end
#=
struct SoundIOOutStream
    ptr::Ptr{SoundIoOutStream_C}
    device::SoundIODevice
    format::Int32
    rate::Int32
end
=#
#=
mutable struct SoundIORingBuffer
    ptr::Ptr{Cvoid}
end
=#
struct SoundIOContext
    ptr::Ref{Ptr{Cvoid}}
    devices::Vector{SoundIODevice}
    streams::Vector{SoundIOOutStream}
    function SoundIOContext()
        ptr = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
        # ptr == C_NULL && error("Failed to create SoundIO context")
        return new(Ref(ptr), SoundIODevice[], SoundIOOutStream[])
    end
end
struct PlaybackTargets
    data_ptr::Ptr{Int32}
    total_frames::Int64
end

# The "Map": Immutable description of the static memory
struct FrozenAudioLayout
    data_ptr::Ptr{Int32}
    total_frames::Int64
    channels::Int32
end

# The "Engine": Mutable state for the active playback
mutable struct FrozenAudioStream
    current_frame::Int64
    is_playing::Bool
    is_finished::Bool
    # Pre-allocated to avoid GC churn in the high-speed callback
    _areas_ref::Ref{Ptr{SoundIoChannelArea_C}}
    _frames_ref::Ref{Cint}
end

# The "Container": The single object we track in Julia
mutable struct FrozenAudioBuffer
    layout::FrozenAudioLayout
    stream::FrozenAudioStream
    
    function FrozenAudioBuffer(ptr::Ptr{Int32}, frames::Integer, channels::Integer)
        lay = FrozenAudioLayout(ptr, Int64(frames), Int32(channels))
        st  = FrozenAudioStream(0, true, false, Ref{Ptr{SoundIoChannelArea_C}}(), Ref{Cint}(0))
        return new(lay, st)
    end
end
