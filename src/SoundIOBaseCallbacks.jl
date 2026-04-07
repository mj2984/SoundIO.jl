@inline get_source_ptr_base(buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {T<:Sample,isatomic,isclearing} = isatomic ? buffer.layout.data_ptr + (buffer.stream.current_offset_base * sizeof(T)) : buffer.layout.data_ptr
@inline get_source_ptr(buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {T<:Sample,isatomic,isclearing} = isatomic ? buffer.layout.data_ptr + ((buffer.stream.current_offset_base + buffer.stream.atomic_frame_offset) * sizeof(T)) : buffer.layout.data_ptr + (buffer.stream.atomic_frame_offset * sizeof(T))
@inline get_frames_to_copy(buffer::FrozenAudioBuffer{T,isatomic,isclearing},actual_frames::Int) where {T<:Sample,isatomic,isclearing} = min(actual_frames, buffer.layout.atom_frames - buffer.stream.atomic_frame_offset)
# TODO:: underrun as type parameter.exit_on_underrun 
@inline stream_direction_transfer!(destination::Ptr{T},source::Ptr{T},frames_to_copy::Int,::Type{SoundIoInputStream_C}) where {T<:Sample} = unsafe_copyto!(source, destination, frames_to_copy)
@inline stream_direction_transfer!(destination::Ptr{T},source::Ptr{T},frames_to_copy::Int,::Type{SoundIoOutputStream_C}) where {T<:Sample} = unsafe_copyto!(destination, source, frames_to_copy)
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
function open_sound_stream(device::SoundIODevice{StreamBaseType}, bufferspec::Tuple{Ptr{T}, Tuple{Integer, Integer}, Bool}, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {StreamBaseType,T<:Sample}
    buffer = FrozenAudioBuffer(bufferspec...)
    callback = make_audio_callback(StreamBaseType,typeof(buffer),frozen_audio_callback)
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, format, latency_seconds)
end
function open_sound_stream(device::SoundIODevice{StreamBaseType}, bufferspec::Type{<:Sample}, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {StreamBaseType}
    buffer = AudioCallbackSynchronizer(bufferspec)
    callback = make_audio_callback(StreamBaseType,typeof(buffer),realtime_audio_callback)
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, format, latency_seconds)
end
open_sound_stream(device::SoundIODevice, bufferspec::Type{<:Sample}, preserve::Any, sample_rate::Integer, latency_seconds::Float64 = 1.0) = open_sound_stream(device,bufferspec,preserve,sample_rate,get_destination_format(bufferspec),latency_seconds)
open_sound_stream(device::SoundIODevice, bufferspec::Tuple{DataType,Integer}, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) = open_sound_stream(device,Sample{bufferspec[2],bufferspec[1]},preserve,sample_rate,format,latency_seconds)
open_sound_stream(device::SoundIODevice, bufferspec::Tuple{DataType,Integer}, preserve::Any, sample_rate::Integer, latency_seconds::Float64 = 1.0) = open_sound_stream(device,Sample{bufferspec[2],bufferspec[1]},preserve,sample_rate,latency_seconds)
is_pointer_safe(::Type{<:DenseArray}) = true
is_pointer_safe(::Type{T}) where {T<:SubArray} = Base.iscontiguous(T)
is_pointer_safe(::Type{<:Base.ReinterpretArray{T, N, S, A}}) where {T, N, S, A} = isbitstype(T) && is_pointer_safe(A)
is_pointer_safe(::Type{<:AbstractArray}) = false
is_pointer_safe(A::AbstractArray) = is_pointer_safe(typeof(A))
function Base.open(device::SoundIODevice, bufferspec::Tuple{AbstractArray{T,N},Bool}, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {T<:Sample,N}
    if (N < 1) 
        error("Audio data must have at least 1 dimensions: (Frames, ...)")
    else
        audio_data,isclearing = bufferspec
        if(!is_pointer_safe(audio_data))
            # throw error
        end
        atom_frames = size(audio_data,1)
        total_atoms = div(length(audio_data),(atom_frames))
        return open_sound_stream(device,(pointer(audio_data),(atom_frames,total_atoms),isclearing),audio_data,sample_rate,format,latency_seconds)
    end
end
function Base.open(device::SoundIODevice, bufferspec::Tuple{AbstractArray{T,N},Bool}, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {T,N}
    if (N < 2) 
        error("Audio data must have at least 2 dimensions: (Channels, Frames, ...)")
    else
        audio_data,isclearing = bufferspec
        if(!is_pointer_safe(audio_data))
            # throw error
        end
        Channels = size(audio_data,1)
        atom_frames = size(audio_data,2)
        total_atoms = div(length(audio_data),(Channels*atom_frames))
        ptr = Base.unsafe_convert(Ptr{Sample{Channels,T}},pointer(audio_data))
        return open_sound_stream(device,(ptr,(atom_frames,total_atoms),isclearing),audio_data,sample_rate,format,latency_seconds)
    end
end
Base.open(device::SoundIODevice, bufferspec::Tuple{AbstractArray{T,N},Bool}, sample_rate::Integer, latency_seconds::Float64 = 1.0) where {T,N} = open(device,bufferspec,sample_rate,get_destination_format(T),latency_seconds)
Base.open(device::SoundIODevice, bufferspec::Tuple{AbstractSampleArray{T,N},Bool}, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {T,N} = open(device,(bufferspec[1].sample,bufferspec[2]),Int(bufferspec[1].rate[1]),format,latency_seconds)
Base.open(device::SoundIODevice, bufferspec::Tuple{AbstractSampleArray{T,N},Bool}, latency_seconds::Float64 = 1.0) where {T,N} = open(device,bufferspec,get_destination_format(T),latency_seconds)
