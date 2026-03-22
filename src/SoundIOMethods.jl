# --- The Audio Callback (Native Thread) ---
@inline function get_audio_buffer(output_stream_ptr::Ptr{SoundIoOutStream_C}, ::Type{BufType}) where {BufType}
    userdata_ptr_ptr = convert(Ptr{Ptr{Cvoid}}, output_stream_ptr + SOUNDIO_OUTSTREAM_USERDATA_OFFSET) # Optimized: Jump directly to userdata to bypass the expensive unsafe_load(output_stream_ptr)
    raw_buffer_ptr   = unsafe_load(userdata_ptr_ptr)
    buffer_ref = unsafe_pointer_to_objref(raw_buffer_ptr)::Ref{BufType}
    return buffer_ref[]::BufType
    #=
    output_stream = unsafe_load(output_stream_ptr)
    buffer = unsafe_pointer_to_objref(output_stream.userdata)
    =#
end
@inline function negotiate_callback_buffer_space(outstream_ptr::Ptr{SoundIoOutStream_C},requested_frames::Cint)
    areas_ref = Ref{Ptr{SoundIoChannelArea_C}}()
    frames_ref = Ref{Cint}(requested_frames) # Frames ref is both an input and output to soundio_outstream_begin_write_ptr. frames_max, frames_min is input from sound driver in the OS. User chooses a frame size based on this and the function checks and returns available memory (updates in place).
    ccall(soundio_outstream_begin_write_ptr, Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), outstream_ptr, areas_ref, frames_ref)
    return unsafe_load(areas_ref[]).ptr, Int(frames_ref[]::Cint) # Note: unsafe_load(areas_ref[]) returns a SoundIoChannelArea_C
end
@inline get_source_ptr_base(buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing}) where {T,Channels,isatomic,isclearing} = isatomic ? Ptr{UInt8}(buffer.layout.data_ptr) + buffer.stream.current_offset_base : Ptr{UInt8}(buffer.layout.data_ptr)
@inline get_frames_to_copy(buffer::FrozenAudioBuffer{T,Channels,isatomic,isclearing},actual_frames::Int) where {T,Channels,isatomic,isclearing} = min(actual_frames, buffer.layout.atom_frames - buffer.stream.atomic_frame_offset)
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
function frozen_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C},frames_min::Cint,frames_max::Cint,::Type{BufType}) where {BufType<:FrozenAudioBuffer}
    buffer::BufType = get_audio_buffer(outstream_ptr,BufType)
    T,Channels,isatomic,isclearing = BufType.parameters
    bytes_per_frame::Int = Channels * sizeof(T)
    buffer_ptr, actual_frames::Int = negotiate_callback_buffer_space(outstream_ptr,frames_max)
    source_ptr_base = get_source_ptr_base(buffer)
    destination_ptr = Base.unsafe_convert(Ptr{UInt8},buffer_ptr) # Base.unsafe_convert(Ptr{T},unsafe_load(buffer_ref.areas[]).ptr)
    frames_to_copy::Int = get_frames_to_copy(buffer,actual_frames)
    if frames_to_copy > 0
        source_ptr = source_ptr_base + (buffer.stream.atomic_frame_offset * bytes_per_frame) # layout.data_ptr + (stream.current_frame * Channels)
        data_bytes_to_copy = frames_to_copy * bytes_per_frame #data_to_copy = frames_to_copy * Channels # In Units of T
        unsafe_copyto!(destination_ptr,source_ptr,data_bytes_to_copy) #unsafe_copyto!(destination_ptr, source_ptr, data_to_copy)
        if isclearing
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), source_ptr, 0, data_bytes_to_copy)
        end
        buffer.stream.atomic_frame_offset += frames_to_copy
    end
    if frames_to_copy < actual_frames
        frozen_audio_callback_boundary_handler!(buffer,destination_ptr,frames_to_copy,actual_frames,bytes_per_frame)
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), outstream_ptr) # Commit to Hardware
    return nothing
end
function realtime_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint, ::Type{BufType}) where {BufType<:AudioCallbackSynchronizer}
    sync::BufType = get_audio_buffer(outstream_ptr,BufType)
    message::AudioCallbackMessage = (@atomic sync.message)
    if message.status == CallbackJuliaDone
        buffer_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr, frames_max)
        if actual_frames > 0
            @atomic sync.message = AudioCallbackMessage(CallbackStatusReady,buffer_ptr,actual_frames)
            while (msg = @atomic sync.message).status == CallbackStatusReady
                ccall(:jl_cpu_pause, Cvoid, ())
            end
        end
    else
        ccall(:uv_async_send, Cint, (Ptr{Cvoid},), sync.notify_handle.handle)
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), outstream_ptr)
    return nothing
end
function make_sound_output_callback(::Type{BufType}, callback_function::F) where {BufType<:SoundIOSynchronizer, F<:Function}
    callback = (out_ptr, f_min, f_max) -> callback_function(out_ptr, f_min, f_max, BufType)
    return @cfunction($callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))
end
# Lifecycle & Check
@inline SoundIO_isopen_context(ctx_ptr) = ctx_ptr != C_NULL
@inline Base.isopen(ctx::SoundIOContext) = SoundIO_isopen_context(ctx.ptr[])
# Connectivity
is_connected_unsafe(ctx::SoundIOContext) = unsafe_load(convert(Ptr{Cint}, ctx.ptr[] + SoundIOBackendMemoryOffsetBytes)) != SoundIOBackendNone
is_connected(ctx::SoundIOContext) = isopen(ctx) && is_connected_unsafe(ctx)
# Allocation
function open_unsafe!(ctx::SoundIOContext)
    ctx.ptr[] = ccall((:soundio_create, libsoundio), Ptr{Cvoid}, ())
    ctx.ptr[] == C_NULL && error("Failed to re-allocate SoundIO context.")
    return
end
function open!(ctx::SoundIOContext)
    !isopen(ctx) && open_unsafe!(ctx)
    return
end
# Handshake
connect_unsafe!(ctx::SoundIOContext) = ccall((:soundio_connect, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[]) != 0 && error("Connect failed")
function connect!(ctx::SoundIOContext)
    !isopen(ctx) && open!(ctx)
    !is_connected(ctx) && connect_unsafe!(ctx)
    return
end
# Severing
disconnect_unsafe!(ctx::SoundIOContext) = ccall((:soundio_disconnect, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
function disconnect!(ctx::SoundIOContext)
    if isopen(ctx) && is_connected(ctx)
        disconnect_unsafe!(ctx)
    end
end
# Cleanup
function Base.close(ctx::SoundIOContext)
    if isopen(ctx)
        disconnect!(ctx)
        empty!(ctx.devices)
        ccall((:soundio_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
        ctx.ptr[] = C_NULL
        #println("🧹 SoundIO Resources Released.")
    end
end
# Event Management
flush_events_unsafe!(ctx::SoundIOContext) = ccall((:soundio_flush_events, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
flush_events!(ctx::SoundIOContext) = isopen(ctx) && flush_events_unsafe!(ctx)
# Blocking Wait
# Note: soundio_wait_events blocks the thread until an event occurs.
@inline SoundIO_wait_unsafe(ctx_ptr) = ccall(soundio_wait_events_ptr, Cvoid, (Ptr{Cvoid},), ctx_ptr)
@inline wait_unsafe(device::SoundIODevice) = SoundIO_wait_unsafe(device.ptrs[].ctx)
@inline wait_unsafe(ctx::SoundIOContext) = SoundIO_wait_unsafe(ctx.ptr[])
@inline Base.wait(ctx::SoundIOContext)= isopen(ctx) && wait_unsafe(ctx)
@inline Base.wait(device::SoundIODevice) = SoundIO_isopen_context(device.ptrs[].ctx) && wait_unsafe(device)
# @inline Base.wait(device::SoundIODevice) = (device.ptrs[].device != C_NULL && SoundIO_isopen_context(device.ptrs[].ctx)) && wait_unsafe(device)
function SoundIOContext(f::Function)
    ctx = SoundIOContext()
    try
        connect!(ctx) # Auto-connect for convenience in do-blocks
        f(ctx)
    finally 
        close(ctx) 
    end
end
function enumerate_devices_unsafe_internal!(ctx::SoundIOContext, ptrs::DeviceEnumeratorPtrs)
    device_count = ccall(ptrs.count, Cint, (Ptr{Cvoid},), ctx.ptr[])
    default_device_offset = ccall(ptrs.default_offset, Cint, (Ptr{Cvoid},), ctx.ptr[])
    for offset in 0:(device_count - 1)
        device_ptr = ccall(ptrs.get_device_ptr, Ptr{Cvoid}, (Ptr{Cvoid}, Cint), ctx.ptr[], offset)
        # if dev_ptr != C_NULL
        # try
        push!(ctx.devices, SoundIODevice(ctx.ptr[], device_ptr, offset == default_device_offset))
        # finally
        ccall(soundio_device_unref_ptr, Cvoid, (Ptr{Cvoid},), device_ptr)
        # end
    end
end
function enumerate_devices_unsafe!(ctx::SoundIOContext)
    flush_events!(ctx)
    empty!(ctx.devices)
    enumerate_devices_unsafe_internal!(ctx, DEVICE_ENUMERATOR_OUTPUT_PTRS)
    enumerate_devices_unsafe_internal!(ctx, DEVICE_ENUMERATOR_INPUT_PTRS)
end
function enumerate_devices!(ctx::SoundIOContext)
    if(is_connected(ctx)) # Ensure we have a valid connection
        enumerate_devices_unsafe!(ctx) #connect!(ctx)
    end
end
list_devices(ctx::SoundIOContext) = ctx.devices
function initialize_sound_stream(device::SoundIODevice)
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptrs[].device)
    out_ptr == C_NULL && error("Failed to create outstream")
    return out_ptr
end
function open_sound_stream_error_check(result::Cint)
    result == 0 && return nothing
    err_sym = get(SoundIoErrorMap, result, :UnknownError) # Get our clean Julia symbol
    c_str_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), result) # Get the official C string for the technical "why"
    c_msg = c_str_ptr != C_NULL ? unsafe_string(c_str_ptr) : "No message provided by libsoundio."
    error("SoundIO [:$err_sym]: $c_msg (Code: $result)")
end
function open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutStream_C})
    result = ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr)
    return result
end
function open_sound_stream(device::SoundIODevice, buffer::T, callback::Base.CFunction, preserve::Any, sample_rate::Integer, format::Int32, latency_seconds::Float64 = 3.0) where {T <: SoundIOSynchronizer}
    out_ptr = initialize_sound_stream(device)
    buffer_ref = Ref(buffer)
    s = unsafe_load(out_ptr) # Load C-struct, update fields
    s.format, s.sample_rate, s.userdata, s.software_latency = Cint(format), Cint(sample_rate), pointer_from_objref(buffer_ref), latency_seconds
    s.write_callback = Base.unsafe_convert(Ptr{Cvoid}, callback)
    # s.error_callback = ERROR_CALLBACK (if defined) (Recommended)
    unsafe_store!(out_ptr, s) # Push back to C memory
    # Negotiate hardware
    result = open_sound_stream_unsafe!(out_ptr)
    open_sound_stream_error_check(result)
    # actual_s = unsafe_load(out_ptr) (Optional: Read back the actual achieved latency)
    stream = SoundIOOutStream(out_ptr, s.format, s.sample_rate, buffer_ref, callback, preserve) #latency_seconds, actual_s.software_latency
    push!(device.streams, stream) 
    return stream
end
function open_sound_stream(device::SoundIODevice, buffer::T, callback::Base.CFunction, preserve::Any, sample_rate::Integer, format::Symbol, latency_seconds::Float64 = 1.0) where {T <: SoundIOSynchronizer}
    if !haskey(SoundIoFormats, format)
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, SoundIoFormats[format], latency_seconds)
end
function open_sound_stream(device::SoundIODevice, buffer::T, callback_function::F, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {T <: SoundIOSynchronizer, F <: Function}
    callback = make_sound_output_callback(T,callback_function)
    return open_sound_stream(device,buffer,callback,preserve,sample_rate,format,latency_seconds)
end
function open_sound_stream(device::SoundIODevice, bufferspec::Tuple{Ptr, Tuple{Integer, Integer, Integer}, Bool}, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0)
    buffer = FrozenAudioBuffer(bufferspec...)
    callback = make_sound_output_callback(typeof(buffer),frozen_audio_callback)
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, format, latency_seconds)
end
function open_sound_stream(device::SoundIODevice, bufferspec::Tuple{DataType,Integer}, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0)
    buffer = AudioCallbackSynchronizer(bufferspec...)
    callback = make_sound_output_callback(typeof(buffer),realtime_audio_callback)
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, format, latency_seconds)
end
is_pointer_safe(::Type{<:DenseArray}) = true
is_pointer_safe(::Type{T}) where {T<:SubArray} = Base.iscontiguous(T)
is_pointer_safe(::Type{<:Base.ReinterpretArray{T, N, S, A}}) where {T, N, S, A} = isbitstype(T) && is_pointer_safe(A)
is_pointer_safe(::Type{<:AbstractArray}) = false
is_pointer_safe(A::AbstractArray) = is_pointer_safe(typeof(A))
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
        return open_sound_stream(device,(pointer(audio_data),(Channels,atom_frames,total_atoms),isclearing),audio_data,sample_rate,format,latency_seconds)
    end
end
# 4. Resume existing stream. (Streams persist over context changes)
function reopen!(stream::SoundIOOutStream)
    stream.ptr == C_NULL && error("Cannot reopen a null stream.")
    result = open_sound_stream_unsafe!(stream.ptr)
    open_sound_stream_error_check(result)
    return nothing
end
function update_callback_status_message(stream::FrozenAudioStream,status::Int8)
    exchange = @atomic stream.exchange
    @atomic stream.exchange = FrozenAudioExchange(exchange.elapsed_frame_bytes,exchange.elapsed_atoms,status)
    return nothing
end
update_callback_status_message(sync::FrozenAudioBuffer,status::Int8) = update_callback_status_message(sync.stream,status)
function update_callback_status_message(sync::AudioCallbackSynchronizer,status::Int8)
    message::AudioCallbackMessage = @atomic sync.message
    @atomic sync.message = AudioCallbackMessage(status,message.data_ptr,message.actual_frames)
    return nothing
end
function start!(stream::SoundIOOutStream)
    update_callback_status_message(stream.sync[],CallbackJuliaDone)
    result = ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
    if(result != 0)
        update_callback_status_message(stream.sync[],Int8(-2))
    end
end
@inline destroy_sound_stream_unsafe(stream::SoundIOOutStream) = ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
@inline function destroy_sound_stream!(device::SoundIODevice,stream_enumeration::Int)
    stream = device.streams[stream_enumeration]
    destroy_sound_stream_unsafe(stream) # TODO:: Destroy async event handles too.
    deleteat!(stream,stream_enumeration)
end
#check_soundio_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))
function supported_formats(device::SoundIODevice)
    formats = Symbol[]
    device_ptr = device.ptrs[].device
    device_ptr == C_NULL && return formats
    count_ptr = convert(Ptr{Cint}, device_ptr + SOUNDIO_DEVICE_FORMAT_COUNT_OFFSET)
    count = unsafe_load(count_ptr)
    # 2. Read the pointer to the formats array (enum SoundIoFormat*)
    formats_ptr_ptr = convert(Ptr{Ptr{Cint}}, device_ptr + SOUNDIO_DEVICE_FORMATS_OFFSET)
    formats_array_ptr = unsafe_load(formats_ptr_ptr)
    if formats_array_ptr != C_NULL
        for i in 0:(count-1)
            f_int = unsafe_load(formats_array_ptr, i + 1)
            for (sym, val) in SoundIoFormats
                val == f_int && push!(formats, sym)
            end
        end
    end
    return formats
end
@inline Base.wait(stream::FrozenAudioStream) = wait(stream.notify_handle)
@inline Base.wait(sync::AudioCallbackSynchronizer) = wait(sync.notify_handle)
@inline get_exchange(stream::FrozenAudioStream) = @atomic stream.exchange
@inline function Base.close(stream::FrozenAudioStream)
    update_callback_status_message(stream,CallbackStopped)
    close(stream.notify_handle)
end
@inline function acquire_sound_buffer_ptr(sync::AudioCallbackSynchronizer{T, Channels}) where {T, Channels}
    local msg::AudioCallbackMessage
    while true
        msg = @atomic sync.message
        if msg.status == CallbackStatusReady
            break # Success: The buffer is ready for Julia to write
        end
        if msg.status <= CallbackStopped
            return convert(Ptr{T}, C_NULL), msg.status # Error or Stopped
        end
        ccall(:jl_cpu_pause, Cvoid, ())
    end
    return convert(Ptr{T}, msg.data_ptr), Int(msg.actual_frames)
end
@inline function acquire_sound_buffer(sync::AudioCallbackSynchronizer{T,Channels}) where {T,Channels}
    ptr, frames_or_status = acquire_sound_buffer_ptr(sync)
    if ptr == C_NULL
        return frames_or_status # Returns the Int8 status code
    end
    #return unsafe_wrap(Matrix{T}, convert(Ptr{T}, hardware_ptr), (channels, actual_frames)) # Create the zero-allocation Matrix view
    return unsafe_wrap(Matrix{T}, ptr, (Channels, frames_or_status))
end
@inline release_sound_buffer(sync::AudioCallbackSynchronizer) = update_callback_status_message(sync,CallbackJuliaDone)
@inline halt_sound_buffer(sync::AudioCallbackSynchronizer) = update_callback_status_message(sync,CallbackStopped)
