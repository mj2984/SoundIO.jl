@inline get_source_ptr_base(buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing}) where {T,Channels,isatomic,isclearing} = isatomic ? Ptr{UInt8}(buffer.layout.data_ptr) + buffer.stream.current_offset_base : Ptr{UInt8}(buffer.layout.data_ptr)
@inline get_frames_to_copy(buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing},actual_frames::Int) where {T,Channels,isatomic,isclearing} = min(actual_frames, buffer.layout.atom_frames - buffer.stream.atomic_frame_offset)
# TODO:: underrun as type parameter.exit_on_underrun 
function frozen_audio_callback_boundary_handler!(buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing}, destination_ptr::Ptr{UInt8}, frames_copied::Int, actual_frames::Int, bytes_per_frame::Int) where {T,Channels,isatomic,isclearing} # Handle Silence / End-of-Buffer-Atom
    layout,stream = buffer.layout, buffer.stream
    exchange::FrozenAudioExchange = @atomic stream.exchange
    pending_frames = actual_frames - frames_copied
    starting_ptr = destination_ptr + (frames_copied * bytes_per_frame)
    pending_bytes = pending_frames * bytes_per_frame
    elapsed_atoms::Int = isatomic ? exchange.elapsed_atoms + 1 : 0
    stream.atomic_frame_offset = pending_frames
    return_status::Int8 = exchange.status
    if return_status == CallbackJuliaDone
        if isatomic
            atom_bytes = layout.atom_frames * bytes_per_frame # assert pending_bytes < atom_bytes (but this should be done outside)
            next_offset_base = (stream.current_offset_base + atom_bytes) % (layout.total_atoms * atom_bytes) # Wrap back to 0 at end of loop.
            stream.current_offset_base = next_offset_base
        end
        next_atom_ptr = get_source_ptr_base(buffer)
        unsafe_copyto!(starting_ptr, next_atom_ptr, pending_bytes)
        if isclearing
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), next_atom_ptr, 0, pending_bytes)
        end
    else
        return_status = CallbackStopped
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), starting_ptr, 0, pending_bytes)
    end
    @atomic stream.exchange = FrozenAudioExchange(pending_frames, elapsed_atoms, return_status)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), stream.notify_handle.handle)
end
function frozen_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint, buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing}) where {T,Channels,isatomic,isclearing}
    bytes_per_frame::Int = Channels * sizeof(T)
    buffer_ptr, actual_frames::Int = negotiate_callback_buffer_space(outstream_ptr, frames_max)
    source_ptr_base = get_source_ptr_base(buffer)
    destination_ptr = Base.unsafe_convert(Ptr{UInt8}, buffer_ptr) # Base.unsafe_convert(Ptr{T}, buffer_ptr}
    frames_to_copy::Int = get_frames_to_copy(buffer, actual_frames)
    if frames_to_copy > 0
        source_ptr = source_ptr_base + (buffer.stream.atomic_frame_offset * bytes_per_frame) # layout.data_ptr + (stream.current_frame * Channels)
        data_bytes_to_copy = frames_to_copy * bytes_per_frame #data_to_copy = frames_to_copy * Channels # In Units of T
        unsafe_copyto!(destination_ptr, source_ptr, data_bytes_to_copy) #unsafe_copyto!(destination_ptr, source_ptr, data_to_copy)
        if isclearing
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), source_ptr, 0, data_bytes_to_copy)
        end
        buffer.stream.atomic_frame_offset += frames_to_copy
    end
    if frames_to_copy < actual_frames
        frozen_audio_callback_boundary_handler!(buffer, destination_ptr, frames_to_copy, actual_frames, bytes_per_frame)
    end
    commit_callback_buffer!(outstream_ptr)
    return nothing
end
function realtime_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint, sync::AudioCallbackSynchronizer)
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
