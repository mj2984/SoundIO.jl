@inline get_source_ptr_base(buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {T<:Sample,isatomic,isclearing} = isatomic ? buffer.layout.data_ptr + (buffer.stream.current_offset_base * sizeof(T)) : buffer.layout.data_ptr
@inline get_source_ptr(buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {T<:Sample,isatomic,isclearing} = isatomic ? buffer.layout.data_ptr + ((buffer.stream.current_offset_base + buffer.stream.atomic_frame_offset) * sizeof(T)) : buffer.layout.data_ptr + (buffer.stream.atomic_frame_offset * sizeof(T))
@inline get_frames_to_copy(buffer::FrozenAudioBuffer{T,isatomic,isclearing},actual_frames::Int) where {T<:Sample,isatomic,isclearing} = min(actual_frames, buffer.layout.atom_frames - buffer.stream.atomic_frame_offset)
# TODO:: underrun as type parameter.exit_on_underrun 
@inline stream_direction_transfer!(destination::Ptr{T},source::Ptr{T},frames_to_copy::Int,::Type{InputSoundStream}) where {T<:Sample} = unsafe_copyto!(source, destination, frames_to_copy)
@inline stream_direction_transfer!(destination::Ptr{T},source::Ptr{T},frames_to_copy::Int,::Type{OutputSoundStream}) where {T<:Sample} = unsafe_copyto!(destination, source, frames_to_copy)
@inline function stream_space_reset!(ptr::Ptr{T}, frames::Integer) where {T<:Sample}
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ptr, 0, frames * sizeof(T))
    return
end
function frozen_audio_callback_boundary_handler!(::Type{StreamBaseType},buffer::FrozenAudioBuffer{T,isatomic,isclearing}, destination_ptr::Ptr{T}, frames_copied::Int, actual_frames::Int) where {StreamBaseType,T<:Sample,isatomic,isclearing} # Handle Silence / End-of-Buffer-Atom
    layout,stream = buffer.layout, buffer.stream
    exchange::FrozenAudioExchange = @atomic stream.exchange
    pending_frames = actual_frames - frames_copied
    starting_ptr = destination_ptr + (frames_copied * sizeof(T))
    stream.atomic_frame_offset = pending_frames
    return_status::Int8 = exchange.status
    if return_status == CallbackJuliaDone
        if isatomic
            next_offset_base = (stream.current_offset_base + layout.atom_frames) % (layout.total_atoms * layout.atom_frames) # Wrap back to 0 at end of loop.
            stream.current_offset_base = next_offset_base
        end
        next_atom_ptr = get_source_ptr_base(buffer)
        stream_direction_transfer!(starting_ptr,next_atom_ptr,pending_frames,StreamBaseType)
        if isclearing
            stream_space_reset!(next_atom_ptr,pending_frames)
        end
    else
        return_status = CallbackStopped
        stream_space_reset!(starting_ptr,pending_frames)
    end
    @atomic stream.exchange = FrozenAudioExchange(pending_frames, exchange.elapsed_atoms + 1, return_status)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), stream.notify_handle.handle)
end
function frozen_audio_callback(outstream_ptr::Ptr{StreamBaseType}, frames_min::Cint, frames_max::Cint, buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {StreamBaseType,T<:Sample,isatomic,isclearing}
    destination_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr, frames_max, T)
    source_ptr = get_source_ptr(buffer)
    frames_to_copy = get_frames_to_copy(buffer, actual_frames)
    if frames_to_copy > 0
        stream_direction_transfer!(destination_ptr, source_ptr, frames_to_copy, StreamBaseType)
        if isclearing
            stream_space_reset!(source_ptr,frames_to_copy)
        end
        buffer.stream.atomic_frame_offset += frames_to_copy
    end
    if frames_to_copy < actual_frames
        frozen_audio_callback_boundary_handler!(StreamBaseType, buffer, destination_ptr, frames_to_copy, actual_frames)
    end
    commit_callback_buffer!(outstream_ptr)
    return nothing
end
function realtime_audio_callback(outstream_ptr::Ptr{StreamBaseType}, frames_min::Cint, frames_max::Cint, sync::AudioCallbackSynchronizer) where {StreamBaseType}
    message::AudioCallbackMessage = (@atomic sync.message)
    if message.status == CallbackJuliaDone
        buffer_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr, frames_max)
        if actual_frames > 0
            @atomic sync.message = AudioCallbackMessage(CallbackStatusReady, buffer_ptr, actual_frames)
            while (msg = @atomic sync.message).status == CallbackStatusReady
                ccall(:jl_cpu_pause, Cvoid, ())
            end
        end
    else
        ccall(:uv_async_send, Cint, (Ptr{Cvoid},), sync.notify_handle.handle)
    end
    commit_callback_buffer!(outstream_ptr)
    return nothing
end
function open_sound_stream(device_configuration::SoundIODeviceConfiguration{StreamBaseType,Mode,Cint,Cint}, bufferspec::Tuple{Ptr{T}, Tuple{Integer, Integer}, Bool}, preserve::Any, latency_seconds::Float64 = 1.0) where {StreamBaseType,Mode,T<:Sample}
    buffer = FrozenAudioBuffer(bufferspec...)
    callback = make_audio_callback(StreamBaseType,typeof(buffer),frozen_audio_callback)
    return open_sound_stream(device_configuration, buffer, callback, preserve, latency_seconds)
end
function open_sound_stream(device_configuration::SoundIODeviceConfiguration{StreamBaseType,Mode,Cint,Cint}, bufferspec::Type{<:Sample}, preserve::Any, latency_seconds::Float64 = 1.0) where {StreamBaseType,Mode}
    buffer = AudioCallbackSynchronizer(bufferspec)
    callback = make_audio_callback(StreamBaseType,typeof(buffer),realtime_audio_callback)
    return open_sound_stream(device_configuration, buffer, callback, preserve, latency_seconds)
end
open_sound_stream(device_configuration::Tuple{SoundIODevice,SoundIoChannelLayout,Union{Symbol,Int32}}, sample_rate::Integer, bufferspec::Tuple{DataType,Integer}, preserve::Any, latency_seconds::Float64 = 1.0) = open_sound_stream(device_configuration,sample_rate,Sample{bufferspec[2],bufferspec[1]},preserve,latency_seconds)
open_sound_stream(device_configuration::Tuple{SoundIODevice,SoundIoChannelLayout}, sample_rate::Integer, bufferspec, preserve::Any, latency_seconds::Float64 = 1.0) = open_sound_stream((device_configuration[1],device_configuration[2],get_destination_format(bufferspec)),sample_rate,bufferspec,preserve,latency_seconds)
is_pointer_safe(A::DenseArray) = true
is_pointer_safe(A::SubArray) = Base.iscontiguous(A)
is_pointer_safe(A::Base.ReinterpretArray{T,N,S,P}) where {T,N,S,P} = isbitstype(T) && is_pointer_safe(parent(A))
is_pointer_safe(A::AbstractArray) = false
is_pointer_safe(A::DomainArray) = is_pointer_safe(A.data)
Base.pointer(A::DomainArray) = pointer(A.data)
@inline function validate_bufferspec(::AbstractArray{T,N}) where {T,N}
    if T <: Sample
        if N < 1
            error("Audio data must have at least 1 dimension: (Frames, ...)")
        end
    else
        if N < 2
            error("Audio data must have at least 2 dimensions: (Channels, Frames, ...)")
        end
    end
end
@inline function compute_frozenbuffer_layout(audio_data::AbstractArray{T,N}) where {T,N}
    if !is_pointer_safe(audio_data)
        error("Audio buffer is not pointer-safe")
    end
    if T <: Sample
        atom_frames = size(audio_data, 1)
        total_atoms = div(length(audio_data), atom_frames)
        ptr = pointer(audio_data)
    else
        Channels = size(audio_data, 1)
        atom_frames = size(audio_data, 2)
        total_atoms = div(length(audio_data), Channels * atom_frames)
        ptr = Base.unsafe_convert(Ptr{Sample{Channels,T}}, pointer(audio_data))
    end
    return ptr, (atom_frames, total_atoms)
end
function resolve_frozen_buffer_device_configuration(device_configuration::SoundIODeviceConfiguration{StreamBaseType,Access,fmt_type,sample_rate_type},audio_data::ArrayType) where {StreamBaseType,Access,fmt_type,sample_rate_type,T,N,ArrayType <: AbstractArray{T,N}}
    if sample_rate_type == Nothing && ArrayType <: DomainArray
        sample_rate = (T <: Sample) ? audio_data.rate[1] : audio_data.rate[2]
        format = fmt_type == Nothing ? get_destination_format(T) : device_configuration.format
        return SoundIODeviceConfiguration(device_configuration.device,device_configuration.layout,sample_rate,format)
    elseif sample_rate_type == Cint
        if ArrayType <: DomainArray
            audio_rate = (T <: Sample) ? audio_data.rate[1] : audio_data.rate[2]
            if device_configuration.sample_rate != audio_rate
                error("Ambiguous sample rate arguments")
            end
        end
        if fmt_type == Nothing
            return SoundIODeviceConfiguration(device_configuration.device,device_configuration.layout,device_configuration.sample_rate,get_destination_format(T))
        else
            return device_configuration
        end
    else
        error("Unable to infer sample rate from Configuration or buffer specification")
    end
end
function Base.open(device_configuration::SoundIODeviceConfiguration,bufferspec::Tuple{T, Bool},latency_seconds::Float64 = 1.0) where {T<:AbstractArray}
    audio_data, isclearing = bufferspec
    validate_bufferspec(audio_data)
    resolved_device_configuration = resolve_frozen_buffer_device_configuration(device_configuration,audio_data)
    ptr, atom_dims::NTuple{2,Int} = compute_frozenbuffer_layout(audio_data)
    return open_sound_stream(resolved_device_configuration,(ptr, atom_dims, isclearing),audio_data,latency_seconds)
end
