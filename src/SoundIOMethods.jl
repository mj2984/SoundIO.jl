# --- The Audio Callback (Native Thread) ---
@inline userdata_offset(::Type{SoundIoInputStream_C})  = SOUNDIO_INPUTSTREAM_USERDATA_OFFSET
@inline userdata_offset(::Type{SoundIoOutputStream_C}) = SOUNDIO_OUTPUTSTREAM_USERDATA_OFFSET
@inline function get_audio_buffer(stream_ptr::Ptr{StreamBaseType}, ::Type{BufType}) where {StreamBaseType,BufType}
    userdata_ptr_ptr = convert(Ptr{Ptr{Cvoid}}, stream_ptr + userdata_offset(StreamBaseType)) # Optimized: Jump directly to userdata to bypass the expensive unsafe_load(output_stream_ptr)
    typed_ref_ptr = convert(Ptr{Base.RefValue{BufType}}, unsafe_load(userdata_ptr_ptr))
    return unsafe_load(typed_ref_ptr)[]::BufType
    #buffer_ref = unsafe_pointer_to_objref(raw_buffer_ptr)::Ref{BufType}
    #return buffer_ref[]::BufType
    #return unsafe_pointer_to_objref(raw_buffer_ptr).x::BufType
    #=
    output_stream = unsafe_load(output_stream_ptr)
    buffer = unsafe_pointer_to_objref(output_stream.userdata)
    =#
end
@inline negotiate_callback_buffer_space_base!(areas_ref::Ref{Ptr{SoundIoChannelArea_C}},frames_ref::Ref{Cint},stream_ptr::Ptr{SoundIoOutputStream_C}) = ccall((:soundio_outstream_begin_write,libsoundio), Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), stream_ptr, areas_ref, frames_ref)
@inline negotiate_callback_buffer_space_base!(areas_ref::Ref{Ptr{SoundIoChannelArea_C}},frames_ref::Ref{Cint},stream_ptr::Ptr{SoundIoInputStream_C}) = ccall((:soundio_instream_begin_read,libsoundio), Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), stream_ptr, areas_ref, frames_ref)
@inline function negotiate_callback_buffer_space(stream_ptr::Ptr{StreamBaseType},requested_frames::Cint) where {StreamBaseType}
    areas_ref = Ref{Ptr{SoundIoChannelArea_C}}()
    frames_ref = Ref{Cint}(requested_frames) # Frames ref is both an input and output to soundio_outstream_begin_write_ptr. frames_max, frames_min is input from sound driver in the OS. User chooses a frame size based on this and the function checks and returns available memory (updates in place).
    negotiate_callback_buffer_space_base!(areas_ref,frames_ref,stream_ptr)
    if(StreamBaseType === SoundIoInputStream_C)
        ptr = areas_ref[]
        actual_ptr = (ptr != C_NULL) ? unsafe_load(ptr).ptr : convert(Ptr{UInt8}, C_NULL)
        return actual_ptr, Int(frames_ref[]::Cint)
    else
        return unsafe_load(areas_ref[]).ptr, Int(frames_ref[]::Cint) # Note: unsafe_load(areas_ref[]) returns a SoundIoChannelArea_C
    end
end
@inline commit_callback_buffer!(stream_ptr::Ptr{SoundIoInputStream_C}) = ccall((:soundio_instream_end_read,libsoundio), Cint, (Ptr{Cvoid},), stream_ptr)
@inline commit_callback_buffer!(stream_ptr::Ptr{SoundIoOutputStream_C}) = ccall((:soundio_outstream_end_write,libsoundio), Cint, (Ptr{Cvoid},), stream_ptr)
function make_audio_callback(::Type{StreamBaseType},::Type{BufType}, callback_function::F) where {StreamBaseType,BufType<:SoundIOSynchronizer, F<:Function}
    callback = (out_ptr, f_min, f_max) -> begin
        buffer::BufType = get_audio_buffer(out_ptr, BufType)
        @inline callback_function(out_ptr, f_min, f_max, buffer)
    end
    return @cfunction($callback, Cvoid, (Ptr{StreamBaseType}, Cint, Cint))
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
#=
function connect_unsafe!(ctx::SoundIOContext)
    check_err(ccall((:soundio_connect, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[]))
end
=#
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
@inline SoundIO_wait_unsafe(ctx_ptr) = ccall((:soundio_wait_events,libsoundio), Cvoid, (Ptr{Cvoid},), ctx_ptr)
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
function get_device_count_and_offset(ctx::SoundIOContext, isinput::Val{true})
    device_count = ccall((:soundio_input_device_count, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    default_device_offset = ccall((:soundio_default_input_device_index, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    return device_count, default_device_offset
end
function get_device_count_and_offset(ctx::SoundIOContext, isinput::Val{false})
    device_count = ccall((:soundio_output_device_count, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    default_device_offset = ccall((:soundio_default_output_device_index, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    return device_count, default_device_offset
end
get_device_ptr(ctx::SoundIOContext, offset::Int, isinput::Val{true}) = ccall((:soundio_get_input_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), ctx.ptr[], offset)
get_device_ptr(ctx::SoundIOContext, offset::Int, isinput::Val{false}) = ccall((:soundio_get_output_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), ctx.ptr[], offset)
function enumerate_devices_unsafe_internal!(ctx::SoundIOContext, directiontype::Val{isinput}) where isinput
    device_count, default_device_offset = get_device_count_and_offset(ctx,directiontype)
    for offset in 0:(device_count - 1)
        device_ptr = get_device_ptr(ctx,offset,directiontype)
        # if dev_ptr != C_NULL
        # try
        push!(ctx.devices, SoundIODevice(ctx.ptr[], device_ptr, offset == default_device_offset))
        # finally
        ccall((:soundio_device_unref,libsoundio), Cvoid, (Ptr{Cvoid},), device_ptr)
        # end
    end
end
function enumerate_devices_unsafe!(ctx::SoundIOContext)
    flush_events!(ctx)
    empty!(ctx.devices)
    enumerate_devices_unsafe_internal!(ctx, Val(true))
    enumerate_devices_unsafe_internal!(ctx, Val(false))
end
function enumerate_devices!(ctx::SoundIOContext)
    if(is_connected(ctx)) # Ensure we have a valid connection
        enumerate_devices_unsafe!(ctx) #connect!(ctx)
    end
end
list_devices(ctx::SoundIOContext) = ctx.devices
initialize_sound_stream_base(device::SoundIODevice{SoundIoInputStream_C}) = ccall((:soundio_instream_create, libsoundio), Ptr{SoundIoInputStream_C}, (Ptr{Cvoid},), device.ptrs[].device)
initialize_sound_stream_base(device::SoundIODevice{SoundIoOutputStream_C}) = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutputStream_C}, (Ptr{Cvoid},), device.ptrs[].device)
function initialize_sound_stream(device::SoundIODevice{StreamBaseType}) where {StreamBaseType}
    out_ptr = initialize_sound_stream_base(device)
    stream_direction = (StreamBaseType === SoundIoInputStream_C) ? "instream" : "outstream"
    out_ptr == C_NULL && error("Failed to create $stream_direction")
    return out_ptr
end
function open_sound_stream_error_check(result::Cint)
    result == 0 && return nothing
    err_sym = get(SoundIoErrorMap, result, :UnknownError) # Get our clean Julia symbol
    c_str_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), result) # Get the official C string for the technical "why"
    c_msg = c_str_ptr != C_NULL ? unsafe_string(c_str_ptr) : "No message provided by libsoundio."
    error("SoundIO [:$err_sym]: $c_msg (Code: $result)")
end
open_sound_stream_unsafe!(ptr::Ptr{SoundIoInputStream_C}) = ccall((:soundio_instream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr)
open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutputStream_C}) = ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr)
#=
function open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutStream_C})
    check_err(ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr))
end
=#
@inline function set_callback!(s::SoundIoOutputStream_C, callback::Base.CFunction)
    s.write_callback = Base.unsafe_convert(Ptr{Cvoid}, callback)
    return s
end
@inline function set_callback!(s::SoundIoInputStream_C, callback::Base.CFunction)
    s.read_callback = Base.unsafe_convert(Ptr{Cvoid}, callback)
    return s
end
function open_sound_stream(device::SoundIODevice{StreamBaseType}, buffer::T, callback::Base.CFunction, preserve::Any, sample_rate::Integer, format::Int32, latency_seconds::Float64 = 3.0) where {StreamBaseType,T <: SoundIOSynchronizer}
    out_ptr = initialize_sound_stream(device)
    buffer_ref = Ref(buffer)
    s = unsafe_load(out_ptr)::StreamBaseType # Load C-struct, update fields
    s.format, s.sample_rate, s.userdata, s.software_latency = Cint(format), Cint(sample_rate), pointer_from_objref(buffer_ref), latency_seconds
    set_callback!(s,callback)
    # s.error_callback = ERROR_CALLBACK (if defined) (Recommended)
    unsafe_store!(out_ptr, s) # Push back to C memory
    # Negotiate hardware
    result = open_sound_stream_unsafe!(out_ptr)
    open_sound_stream_error_check(result)
    # actual_s = unsafe_load(out_ptr) (Optional: Read back the actual achieved latency)
    stream = SoundIOStream{StreamBaseType,T}(out_ptr, s.format, s.sample_rate, buffer_ref, callback, preserve) #latency_seconds, actual_s.software_latency
    push!(device.streams, stream) 
    return stream
end
function open_sound_stream(device::SoundIODevice, buffer::T, callback::Base.CFunction, preserve::Any, sample_rate::Integer, format::Symbol, latency_seconds::Float64 = 1.0) where {T <: SoundIOSynchronizer}
    if !haskey(SoundIoFormats, format)
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    return open_sound_stream(device, buffer, callback, preserve, sample_rate, SoundIoFormats[format], latency_seconds)
end
function open_sound_stream(device::SoundIODevice{StreamBaseType}, buffer::T, callback_function::F, preserve::Any, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0) where {StreamBaseType, T <: SoundIOSynchronizer, F <: Function}
    callback = make_audio_callback(StreamBaseType,T,callback_function)
    return open_sound_stream(device,buffer,callback,preserve,sample_rate,format,latency_seconds)
end
function get_destination_format(::Type{T}) where T
    T === Int16   && return SoundIoFormats[:Int16Little]
    T === Int32   && return SoundIoFormats[:Int32Little]
    T === Int24   && return SoundIoFormats[:Int24Little]
    T === Float32 && return SoundIoFormats[:Float32Little]
    T === Float64 && return SoundIoFormats[:Float64Little]
    # Fallback for types that aren't leaf-level integers/floats
    error("No audio format mapping for type: $T")
end
get_destination_format(::Type{<:Fixed{T, f}}) where {T, f} = get_destination_format(T)
get_destination_format(::Type{Sample{N, T}}) where {N, T} = get_destination_format(T)

# 4. Resume existing stream. (Streams persist over context changes)
function reopen!(stream::SoundIOStream)
    stream.ptr == C_NULL && error("Cannot reopen a null stream.")
    result = open_sound_stream_unsafe!(stream.ptr)
    open_sound_stream_error_check(result)
    return nothing
end
@inline function update_callback_status_message(stream::FrozenAudioStream,status::Int8)
    exchange = @atomic stream.exchange
    @atomic stream.exchange = FrozenAudioExchange(exchange.elapsed_frame_bytes,exchange.elapsed_atoms,status)
    return nothing
end
@inline update_callback_status_message(sync::FrozenAudioBuffer,status::Int8) = update_callback_status_message(sync.stream,status)
function update_callback_status_message(sync::AudioCallbackSynchronizer,status::Int8)
    message::AudioCallbackMessage = @atomic sync.message
    @atomic sync.message = AudioCallbackMessage(status,message.data_ptr,message.actual_frames)
    return nothing
end
@inline start_base(stream::SoundIOStream{SoundIoInputStream_C, T}) where {T} = ccall((:soundio_instream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
@inline start_base(stream::SoundIOStream{SoundIoOutputStream_C, T}) where {T} = ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
function start!(stream::SoundIOStream{S, T}) where {S,T}
    update_callback_status_message(stream.sync[],CallbackJuliaDone)
    result = start_base(stream)
    if(result != 0)
        update_callback_status_message(stream.sync[],Int8(-2))
    end
end
#=
function start!(stream::SoundIOOutStream)
    update_callback_status_message(stream.sync[], CallbackJuliaDone)
    check_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr))
end
=#
@inline destroy_sound_stream_unsafe(stream::SoundIOStream{SoundIoInputStream_C, T}) where {T} = ccall((:soundio_instream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
@inline destroy_sound_stream_unsafe(stream::SoundIOStream{SoundIoOutputStream_C, T}) where {T} = ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
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
    return unsafe_wrap(Array, convert(Ptr{Sample{Channels, T}}, ptr), (frames_or_status))
end
@inline release_sound_buffer(sync::AudioCallbackSynchronizer) = update_callback_status_message(sync,CallbackJuliaDone)
@inline halt_sound_buffer(sync::AudioCallbackSynchronizer) = update_callback_status_message(sync,CallbackStopped)

@inline function Base.getproperty(d::SoundIODevice{S}, s::Symbol) where S
    if s === :is_input
        return S === SoundIoInputStream_C
    elseif s === :is_output
        return S === SoundIoOutputStream_C
    else
        return getfield(d, s)
    end
end
