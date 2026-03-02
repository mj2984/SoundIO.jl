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
    format::SoundIoFormat
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
# --- The Playback Control Bridge ---
mutable struct PlaybackState
    data_ptr::Ptr{Int32}
    total_frames::Int64
    current_frame::Int64
    channels::Int32
    is_playing::Bool     # New: Pause Control
    volume::Float32      # New: Volume Control (0.0 to 1.0)
end
