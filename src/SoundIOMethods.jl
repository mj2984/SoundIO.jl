# --- The Audio Callback (Native Thread) ---
@inline function get_audio_buffer(output_stream_ptr::Ptr{SoundIoOutStream_C})
    userdata_ptr_ptr = convert(Ptr{Ptr{Cvoid}}, output_stream_ptr + SOUNDIO_OUTSTREAM_USERDATA_OFFSET) # Optimized: Jump directly to userdata to bypass the expensive unsafe_load(output_stream_ptr)
    raw_buffer_ptr   = unsafe_load(userdata_ptr_ptr)
    return unsafe_pointer_to_objref(raw_buffer_ptr)
    #=
    output_stream = unsafe_load(output_stream_ptr)
    buffer = unsafe_pointer_to_objref(output_stream.userdata)
    =#
end
@inline function negotiate_callback_buffer_space(outstream_ptr::Ptr{SoundIoOutStream_C},requested_frames::Cint)
    areas_ref = Ref{Ptr{SoundIoChannelArea_C}}()
    frames_ref = Ref{Cint}(requested_frames) # Frames ref is both an input and output to soundio_outstream_begin_write_ptr. frames_max, frames_min is input from sound driver in the OS. User chooses a frame size based on this and the function checks and returns available memory (updates in place).
    ccall(soundio_outstream_begin_write_ptr, Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), outstream_ptr, areas_ref, frames_ref)
    return unsafe_load(areas_ref[]).ptr, frames_ref[] # Note: unsafe_load(areas_ref[]) returns a SoundIoChannelArea_C
end
function frozen_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C},frames_min::Cint,frames_max::Cint,::Type{BufType}) where {BufType<:FrozenAudioBuffer}
    buffer::BufType = get_audio_buffer(outstream_ptr) # Recover the Julia Object
    T,Channels = BufType.parameters
    layout::FrozenAudioLayout{T}, stream::FrozenAudioStream = buffer.layout, buffer.stream
    buffer_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr,frames_max)
    destination_ptr = Base.unsafe_convert(Ptr{UInt8},buffer_ptr) # Base.unsafe_convert(Ptr{T},unsafe_load(buffer_ref.areas[]).ptr)
    remaining_frames = layout.total_frames - stream.current_frame
    frames_to_copy = min(actual_frames, remaining_frames)
    if frames_to_copy > 0 # (stream.status == CallbackJuliaDone) && # This check has been removed since we are not looking to halt memory playback during runtime.
        source_ptr = Base.unsafe_convert(Ptr{UInt8},layout.data_ptr) + (stream.current_frame * Channels * sizeof(T)) # layout.data_ptr + (stream.current_frame * Channels)
        data_bytes_to_copy = frames_to_copy * Channels * sizeof(T) #data_to_copy = frames_to_copy * Channels # In Units of T
        unsafe_copyto!(destination_ptr,source_ptr,data_bytes_to_copy) #unsafe_copyto!(destination_ptr, source_ptr, data_to_copy)
        stream.current_frame += frames_to_copy
    end
    if frames_to_copy < actual_frames # Handle Silence / End-of-Buffer
        silence_frames = actual_frames - frames_to_copy
        silence_ptr = destination_ptr + (frames_to_copy * Channels * sizeof(T))
        total_silence_bytes = silence_frames * Channels * sizeof(T)
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), silence_ptr, 0, total_silence_bytes)
        #silence_view = unsafe_wrap(Array, convert(Ptr{UInt8}, hardware_ptr) + silence_offset_bytes, total_silence_bytes)
        #fill!(silence_view, zero(UInt8))
        if stream.current_frame >= layout.total_frames
            if(stream.status == CallbackJuliaDone)
                stream.current_frame = 0
            else
                stream.status = -1 # :inactive
            end
        end
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), outstream_ptr) # Commit to Hardware
    return nothing
end
#=
function realtime_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint,::Type{BufType}) where {BufType<:AudioCallbackSynchronizer}
    sync::BufType = get_audio_buffer(outstream_ptr)
    T,Channels = BufType.parameters
    if (@atomic sync.status) == CallbackJuliaDone
        buffer_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr,frames_max)
        if actual_frames > 0
            @atomic sync.current_buffer = unsafe_wrap(Matrix{T}, convert(Ptr{T}, buffer_ptr), (Channels, actual_frames)) # This update must be atomic so the worker task sees the new Matrix header
            @atomic sync.status = CallbackStatusReady # Signal the Julia side that the hardware buffer is ready
            while (@atomic sync.status) == CallbackStatusReady # Spin-lock until Julia signals done or an error occurs
                ccall(:jl_cpu_pause, Cvoid, ())
            end
        end
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), outstream_ptr)
    return nothing
end
=#
function realtime_audio_callback(outstream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint, ::Type{BufType}) where {BufType<:AudioCallbackSynchronizer}
    sync::BufType = get_audio_buffer(outstream_ptr)
    if (@atomic sync.status) == CallbackJuliaDone
        buffer_ptr, actual_frames = negotiate_callback_buffer_space(outstream_ptr, frames_max)
        if actual_frames > 0
            # Atomically publish the raw facts to the worker
            @atomic sync.data_ptr = buffer_ptr
            @atomic sync.actual_frames = Int32(actual_frames)
            @atomic sync.status = CallbackStatusReady 
            # Spin-lock
            while (@atomic sync.status) == CallbackStatusReady
                ccall(:jl_cpu_pause, Cvoid, ())
            end
        end
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), outstream_ptr)
    return nothing
end
function make_sound_output_callback(::Type{BufType}) where {BufType<:FrozenAudioBuffer}
    callback = (outstream_ptr, frames_min, frames_max) -> frozen_audio_callback(outstream_ptr, frames_min, frames_max, BufType) # Define the specific closure
    return @cfunction($callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint)) # Use $ to interpolate the closure into the macro
end
function make_sound_output_callback(::Type{BufType}) where {BufType<:AudioCallbackSynchronizer}
    callback = (outstream_ptr, frames_min, frames_max) -> realtime_audio_callback(outstream_ptr, frames_min, frames_max, BufType)
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
function open_sound_stream(device::SoundIODevice, buffer::T, sample_rate::Integer, format::Int32, latency_seconds::Float64 = 3.0) where {T <: SoundIOSynchronizer}
    out_ptr = initialize_sound_stream(device)
    callback = make_sound_output_callback(typeof(buffer))
    s = unsafe_load(out_ptr) # Load C-struct, update fields
    s.format, s.sample_rate, s.userdata, s.software_latency = Cint(format), Cint(sample_rate), pointer_from_objref(buffer), latency_seconds
    s.write_callback = Base.unsafe_convert(Ptr{Cvoid}, callback)
    # s.error_callback = ERROR_CALLBACK (if defined) (Recommended)
    unsafe_store!(out_ptr, s) # Push back to C memory
    # Negotiate hardware
    result = open_sound_stream_unsafe!(out_ptr)
    open_sound_stream_error_check(result)
    # actual_s = unsafe_load(out_ptr) (Optional: Read back the actual achieved latency)
    stream = SoundIOOutStream(out_ptr, s.format, s.sample_rate, buffer, callback) #latency_seconds, actual_s.software_latency
    push!(device.streams, stream) 
    return stream
end
function open_sound_stream(device::SoundIODevice, buffer::T, sample_rate::Integer, format::Symbol, latency_seconds::Float64 = 1.0) where {T <: SoundIOSynchronizer}
    if !haskey(SoundIoFormats, format)
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    return open_sound_stream(device, buffer, sample_rate, SoundIoFormats[format], latency_seconds)
end
function Base.open(device::SoundIODevice, bufferspec, channels::Integer, sample_rate::Integer, format::Union{Symbol,Int32}, latency_seconds::Float64 = 1.0)
    if(bufferspec isa Tuple{Ptr{T},Integer} where T)
        buffer = FrozenAudioBuffer(bufferspec...,channels)
    else
        buffer = AudioCallbackSynchronizer(bufferspec,channels)
    end
    return open_sound_stream(device, buffer, sample_rate, format, latency_seconds)
end
# 4. Resume existing stream. (Streams persist over context changes)
function reopen!(stream::SoundIOOutStream)
    stream.ptr == C_NULL && error("Cannot reopen a null stream.")
    result = open_sound_stream_unsafe!(stream.ptr)
    open_sound_stream_error_check(result)
    return nothing
end
function set_julia_start_message(sync::FrozenAudioBuffer,message::Int8)
    sync.stream.status = message
    return nothing
end
function set_julia_start_message(sync::AudioCallbackSynchronizer,message::Int8)
    @atomic sync.status = message
    return nothing
end
function start!(stream::SoundIOOutStream)
    set_julia_start_message(stream.sync,CallbackJuliaDone)
    result = ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
    if(result != 0)
        set_julia_start_message(stream.sync,Int8(-2))
    end
end
@inline destroy_sound_stream_unsafe(stream::SoundIOOutStream) = ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
@inline function destroy_sound_stream!(device::SoundIODevice,stream_enumeration::Int)
    stream = device.streams[stream_enumeration]
    destroy_sound_stream(stream)
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
function play_audio(audio_data::Matrix{T}, sample_rate::Integer, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32}, T<:Number}
    channels, frames = size(audio_data)
    GC.@preserve audio_data begin # Preserve audio data from GC during the C thread's run
        stream = open(device, (pointer(audio_data), frames), channels, sample_rate, format)
        buffer = stream.sync
        start!(stream)
        #println("🔊 Playback started. Press Ctrl+C to stop.")
        try
            # Main Control Loop
            while buffer.stream.status == 2
                wait_unsafe(device) # wait_events is efficient; it sleeps the thread until an event occurs
                #yield() Small sleep to yield to Julia scheduler for REPL interactivity
            end
        finally
            ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr) # Stop stream playback when done or interrupted
            #filter!(s -> s != stream_ptr, ctx.streams)
        end
    end
    #=
        GC.@preserve audio_data state ctx audio_device begin
        stream = open_outstream_direct(audio_device, SoundIO.S32LE, Int(sample_rate), state)
        while state.current_frame < state.total_frames
            wait_events(ctx)
            sleep(0.1) # Main loop is idle, audio runs in background thread
        end
    end=#
    #println("✅ Playback finished.")
end
#=
@inline function acquire_sound_buffer(sync::AudioCallbackSynchronizer{T,channels}) where {T,channels}
    s::Int8 = @atomic sync.status
    while s != CallbackStatusReady
        if s <= CallbackStopped
            return get(CallbackStatusEnumerations, s, :unknown_error)
        end
        ccall(:jl_cpu_pause, Cvoid, ())
        s = @atomic sync.status
    end
    #=
    buffer_ref = sync.buffer_ref
    actual_frames = Int(buffer_ref.frames[])
    hardware_ptr = unsafe_load(buffer_ref.areas[]).ptr
    return unsafe_wrap(Matrix{T}, convert(Ptr{T}, hardware_ptr), (channels, actual_frames)) # Create the zero-allocation Matrix view
    =#
    return @atomic sync.current_buffer
end
=#
@inline function acquire_sound_buffer_ptr(sync::AudioCallbackSynchronizer{T, Channels}) where {T, Channels}
    # Spin until ready
    while (s = @atomic sync.status) != CallbackStatusReady
        s <= CallbackStopped && return C_NULL, 0
        ccall(:jl_cpu_pause, Cvoid, ())
    end
    # Return the raw hardware details
    return convert(Ptr{T}, @atomic sync.data_ptr), Int(@atomic sync.actual_frames)
end
@inline function message_and_release_sound_buffer(sync::AudioCallbackSynchronizer,status::Int8)
    @atomic sync.status = status
    return nothing
end
@inline release_sound_buffer(sync::AudioCallbackSynchronizer) = message_and_release_sound_buffer(sync,CallbackJuliaDone)
@inline halt_sound_buffer(sync::AudioCallbackSynchronizer) = message_and_release_sound_buffer(sync,CallbackStopped)
