struct SoundDeviceChannelArea_C
    ptr::Ptr{UInt8}
    step::Cint
end
struct SoundDeviceChannelLayout
    name::Ptr{Cchar}
    channel_count::Cint #Int32
    channels::NTuple{24, Cint} #NTuple{24, Int32}
end
# --- Playback Logic ---
struct FrozenAudioLayout{T<:Sample,isatomic,isclearing} # The "Map": Immutable description of the static memory
    data_ptr::Ptr{T}
    atom_frames::Int
    total_atoms::Int
    FrozenAudioLayout(data_ptr::Ptr{T},atom_dimensions::NTuple{2,Int},isclearing::Bool) where {T<:Sample} = new{T,atom_dimensions[2]!=1,isclearing}(data_ptr,atom_dimensions...)
end
struct FrozenAudioExchange
    elapsed_frame_bytes::Int
    elapsed_atoms::Int
    status::Int8
end
mutable struct FrozenAudioStream # The "Engine": Mutable state for the active playback
    atomic_frame_offset::Int
    current_offset_base::Int
    @atomic exchange::FrozenAudioExchange # A synchronized view that only provides updates atomically at atom boundary crossing.
    notify_handle::Base.AsyncCondition
    FrozenAudioStream() = new(0, 0, FrozenAudioExchange(0, 0, CallbackStopped), Base.AsyncCondition())
end
abstract type SoundDeviceSynchronizer end
struct FrozenAudioBuffer{T<:Sample,isatomic,isclearing} <: SoundDeviceSynchronizer # The "Container": The single object we track in Julia
    layout::FrozenAudioLayout{T,isatomic,isclearing}
    stream::FrozenAudioStream
    function FrozenAudioBuffer(ptr::Ptr{T}, specification_dimensions::Tuple{Integer,Integer}, isclearing::Bool) where {T<:Sample}
        atom_frames::Int, total_atoms::Int = specification_dimensions
        layout = FrozenAudioLayout(ptr, (atom_frames, total_atoms), isclearing)
        stream = FrozenAudioStream()
        return new{T,total_atoms!=1,isclearing}(layout, stream)
    end
end
struct AudioCallbackMessage
    status::Int8
    data_ptr::Ptr{Cvoid} # Raw hardware address
    actual_frames::Int # Negotiated frame count
end
mutable struct AudioCallbackSynchronizer{T,Channels} <: SoundDeviceSynchronizer
    @atomic message::AudioCallbackMessage
    notify_handle::Base.AsyncCondition
    AudioCallbackSynchronizer(::Type{Sample{Channels,T}}) where {Channels,T} = new{T, Channels}(AudioCallbackMessage(CallbackStopped, C_NULL, 0),Base.AsyncCondition())
    AudioCallbackSynchronizer(T, Channels::Integer) = new{T, Channels}(AudioCallbackMessage(CallbackStopped, C_NULL, 0),Base.AsyncCondition())
end
# Internal C-struct for safe pointer access
struct SoundDevice_C
    soundio::Ptr{Cvoid}
    id::Ptr{Cchar}
    name::Ptr{Cchar}
    aim::Cint
    layouts::Ptr{SoundDeviceChannelLayout}
    layout_count::Cint
    current_layout::SoundDeviceChannelLayout
    formats::Ptr{Cint}
    format_count::Cint
    current_format::Cint
    sample_rates::Ptr{Cvoid}
    sample_rate_count::Cint
    sample_rate_current::Cint
    software_latency_min::Cdouble
    software_latency_max::Cdouble
    software_latency_current::Cdouble
    is_raw::UInt8
    # 3 bytes padding here on most ABIs
    ref_count::Cint
    probe_error::Cint
end
mutable struct OutputSoundStream
    device::Ptr{Cvoid}
    format::Cint
    sample_rate::Cint
    layout::SoundDeviceChannelLayout
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
mutable struct InputSoundStream
    device::Ptr{Cvoid}
    format::Cint
    sample_rate::Cint
    layout::SoundDeviceChannelLayout
    software_latency::Cdouble
    userdata::Ptr{Cvoid}
    read_callback::Ptr{Cvoid}
    overflow_callback::Ptr{Cvoid}
    error_callback::Ptr{Cvoid}
    name::Ptr{Cchar}
    non_terminal_hint::Cint
    bytes_per_frame::Cint
    bytes_per_sample::Cint
    layout_error::Cint
end
struct SoundDeviceStream{StreamBaseType,T <: SoundDeviceSynchronizer}
    ptr::Ptr{StreamBaseType}
    format::Cint
    rate::Cint
    sync::Ref{T}
    callback_ptr::Base.CFunction
    anchor::Any
end
struct SoundDevicePtrs
    device::Ptr{Cvoid}
    ctx::Ptr{Cvoid}
end
struct SoundDevice{StreamBaseType,Access}
    ptrs::Base.RefValue{SoundDevicePtrs}
    name::String
    id::String
    is_default::Bool
    formats::Memory{Cint}
    layouts::Memory{SoundDeviceChannelLayout}
    streams::Vector{SoundDeviceStream{StreamBaseType,<:SoundDeviceSynchronizer}}
    function SoundDevice(ctx_ptr::Ptr{Cvoid}, device_ptr::Ptr{Cvoid}, is_default::Bool)
        c_dev = unsafe_load(convert(Ptr{SoundDevice_C}, device_ptr))
        formats, layouts, name, id, aim, is_raw = get_sound_device_parameters(c_dev)
        ccall((:soundio_device_ref, libsoundio), Cvoid, (Ptr{Cvoid},), device_ptr) # Increment C-ref count to keep memory alive while this Julia object exists
        StreamBaseType = aim == 0 ? InputSoundStream : OutputSoundStream
        Access = is_raw != 0 ? :raw : :shared
        return new{StreamBaseType,Access}(Ref(SoundDevicePtrs(device_ptr, ctx_ptr)), name, id, is_default, formats, layouts, Vector{SoundDeviceStream{StreamBaseType, <:SoundDeviceSynchronizer}}())        # Decrement Ref Count on GC
        #=finalizer(dev) do d
            for s in d.streams
                if(StreamBaseType == SoundIoOutputStream_C)
                    ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), s.ptr)
                else
                    ccall((:soundio_instream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), s.ptr)
                end
            end
            ccall((:soundio_device_unref, libsoundio), Cvoid, (Ptr{Cvoid},), d.ptr)
        end
        return dev
        =#
    end
end
struct SoundDeviceConfiguration{StreamBaseType,Access}
    device::SoundDevice{StreamBaseType,Access}
    layout::SoundDeviceChannelLayout
    sample_rate::Cint
    format::Cint
    latency::Cdouble
    SoundDeviceConfiguration(device::SoundDevice{StreamBaseType,Access},layout::SoundDeviceChannelLayout,sample_rate::Number,format::Integer,latency::Number=1.0) where {StreamBaseType,Access} = new{StreamBaseType,Access}(device,layout,Cint(sample_rate),format,Cdouble(latency))
    SoundDeviceConfiguration(device::SoundDevice{StreamBaseType,Access},layout::SoundDeviceChannelLayout,sample_rate::Number,format::Type{T},latency::Number=1.0) where {StreamBaseType,Access,T} = SoundDeviceConfiguration(device,layout,sample_rate,get_destination_format(format),latency)
    SoundDeviceConfiguration(device::SoundDevice{StreamBaseType,Access},layout::SoundDeviceChannelLayout,sample_rate::Number,format::Symbol,latency::Number=1.0) where {StreamBaseType,Access} = SoundDeviceConfiguration(device,layout,sample_rate,get_destination_format(format),latency)
end
struct SoundDeviceGroup{Access}
    inputs::Vector{SoundDevice{InputSoundStream, Access}}
    outputs::Vector{SoundDevice{OutputSoundStream, Access}}
    SoundDeviceGroup(Access::Symbol) = new{Access}(Vector{SoundDevice{InputSoundStream, Access}}(),Vector{SoundDevice{OutputSoundStream, Access}}())
end
struct SoundDevices
    raw::SoundDeviceGroup{:raw}
    shared::SoundDeviceGroup{:shared}
    SoundDevices() = new(SoundDeviceGroup(:raw),SoundDeviceGroup(:shared))
end
struct SoundDeviceContext
    ptr::Base.RefValue{Ptr{Cvoid}}
    devices::SoundDevices
    function SoundDeviceContext()
        p = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
        p == C_NULL && error("Failed to create Sound Device context")
        return new(Ref(p), SoundDevices())
    end
end
const SOUNDDEVICE_OUTPUTSTREAM_USERDATA_OFFSET = fieldoffset(OutputSoundStream, 7)
const SOUNDDEVICE_INPUTSTREAM_USERDATA_OFFSET = fieldoffset(InputSoundStream, 6)
