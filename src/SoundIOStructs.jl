struct SoundIoChannelArea_C
    ptr::Ptr{UInt8}
    step::Cint
end
struct SoundIoChannelLayout
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
abstract type SoundIOSynchronizer end
struct FrozenAudioBuffer{T<:Sample,isatomic,isclearing} <: SoundIOSynchronizer # The "Container": The single object we track in Julia
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
mutable struct AudioCallbackSynchronizer{T,Channels} <: SoundIOSynchronizer
    @atomic message::AudioCallbackMessage
    notify_handle::Base.AsyncCondition
    AudioCallbackSynchronizer(::Type{Sample{Channels,T}}) where {Channels,T} = new{T, Channels}(AudioCallbackMessage(CallbackStopped, C_NULL, 0),Base.AsyncCondition())
    AudioCallbackSynchronizer(T, Channels::Integer) = new{T, Channels}(AudioCallbackMessage(CallbackStopped, C_NULL, 0),Base.AsyncCondition())
end
# Internal C-struct for safe pointer access
struct SoundIoDevice_C
    soundio::Ptr{Cvoid}                     # struct SoundIo *soundio;
    id::Ptr{Cchar}                          # char *id;
    name::Ptr{Cchar}                        # char *name;
    aim::Cint                               # enum SoundIoDeviceAim aim;

    layouts::Ptr{SoundIoChannelLayout}    # struct SoundIoChannelLayout *layouts;
    layout_count::Cint                      # int layout_count;
    current_layout::SoundIoChannelLayout  # struct SoundIoChannelLayout current_layout;

    formats::Ptr{Cint}                      # enum SoundIoFormat *formats;
    format_count::Cint                      # int format_count;
    current_format::Cint                    # enum SoundIoFormat current_format;

    sample_rates::Ptr{Cvoid}                # struct SoundIoSampleRateRange *sample_rates;
    sample_rate_count::Cint                 # int sample_rate_count;
    sample_rate_current::Cint               # int sample_rate_current;

    software_latency_min::Cdouble           # double software_latency_min;
    software_latency_max::Cdouble           # double software_latency_max;
    software_latency_current::Cdouble       # double software_latency_current;

    is_raw::UInt8                           # bool is_raw;
    # 3 bytes padding here on most ABIs
    ref_count::Cint                         # int ref_count;
    probe_error::Cint                       # int probe_error;
end
mutable struct OutputSoundStream
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
mutable struct InputSoundStream
    device::Ptr{Cvoid}
    format::Cint
    sample_rate::Cint
    layout::SoundIoChannelLayout
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
struct SoundIOStream{StreamBaseType,T <: SoundIOSynchronizer}
    ptr::Ptr{StreamBaseType}
    format::Cint
    rate::Cint
    sync::Ref{T}
    callback_ptr::Base.CFunction
    anchor::Any
end
struct SoundIODevicePtrs
    device::Ptr{Cvoid}
    ctx::Ptr{Cvoid}
end
struct SoundIODevice{StreamBaseType,Access}
    ptrs::Base.RefValue{SoundIODevicePtrs}
    name::String
    id::String
    is_default::Bool
    formats::Memory{Cint}
    layouts::Memory{SoundIoChannelLayout}
    streams::Vector{SoundIOStream{StreamBaseType,<:SoundIOSynchronizer}}
    function SoundIODevice(ctx_ptr::Ptr{Cvoid}, device_ptr::Ptr{Cvoid}, is_default::Bool)
        c_dev = unsafe_load(convert(Ptr{SoundIoDevice_C}, device_ptr))
        formats, layouts, name, id, aim, is_raw = get_sound_device_parameters(c_dev)
        ccall((:soundio_device_ref, libsoundio), Cvoid, (Ptr{Cvoid},), device_ptr) # Increment C-ref count to keep memory alive while this Julia object exists
        StreamBaseType = aim == 0 ? InputSoundStream : OutputSoundStream
        Access = is_raw != 0 ? :raw : :shared
        return new{StreamBaseType,Access}(Ref(SoundIODevicePtrs(device_ptr, ctx_ptr)), name, id, is_default, formats, layouts, Vector{SoundIOStream{StreamBaseType, <:SoundIOSynchronizer}}())        # Decrement Ref Count on GC
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
resolve_soundio_format(::Nothing) = nothing
resolve_soundio_format(::Type{T}) where {T} = get_destination_format(T)
resolve_soundio_format(format::Symbol) = get_destination_format(format)
resolve_soundio_format(format::Integer) = Cint(format)
struct SoundIODeviceConfiguration{StreamBaseType,Access,fmt_type<:Union{Cint,Nothing},sample_rate_type<:Union{Cint,Nothing}}
    device::SoundIODevice{StreamBaseType,Access}
    layout::SoundIoChannelLayout
    sample_rate::sample_rate_type
    format::fmt_type
    function SoundIODeviceConfiguration(device::SoundIODevice{StreamBaseType,Access},layout::Union{SoundIoChannelLayout,Integer},sample_rate::Union{Integer,Nothing},format::Union{Type{T},Symbol,Integer,Nothing}) where {StreamBaseType,Access,T}
        layout_resolved = layout isa SoundIoChannelLayout ? layout : device.layouts[layout]
        sample_rate_resolved = sample_rate isa Nothing ? nothing : Cint(sample_rate)
        format_resolved = resolve_soundio_format(format)
        new{StreamBaseType,Access,typeof(sample_rate_resolved),typeof(format_resolved)}(device,layout_resolved,sample_rate_resolved,format_resolved)
    end
end
struct SoundIODeviceGroup{Access}
    inputs::Vector{SoundIODevice{InputSoundStream, Access}}
    outputs::Vector{SoundIODevice{OutputSoundStream, Access}}
    SoundIODeviceGroup(Access::Symbol) = new{Access}(Vector{SoundIODevice{InputSoundStream, Access}}(),Vector{SoundIODevice{OutputSoundStream, Access}}())
end
struct SoundIODevices
    raw::SoundIODeviceGroup{:raw}
    shared::SoundIODeviceGroup{:shared}
    SoundIODevices() = new(SoundIODeviceGroup(:raw),SoundIODeviceGroup(:shared))
end
struct SoundIOContext
    ptr::Base.RefValue{Ptr{Cvoid}}
    devices::SoundIODevices
    function SoundIOContext()
        p = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
        p == C_NULL && error("Failed to create SoundIO context")
        return new(Ref(p), SoundIODevices())
    end
end
const SOUNDIO_OUTPUTSTREAM_USERDATA_OFFSET = fieldoffset(OutputSoundStream, 7)
const SOUNDIO_INPUTSTREAM_USERDATA_OFFSET = fieldoffset(InputSoundStream, 6)
