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
function frozen_audio_callback(output_stream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint)
    # 1. Recover the Julia Object (Optimized)
    buffer::FrozenAudioBuffer = get_audio_buffer(output_stream_ptr)
    layout, stream = buffer.layout, buffer.stream
    # 2. Negotiate Buffer Space. Frames ref in both an input and output to soundio_outstream_begin_write_ptr.
    # frames_max, frames_min is input from sound driver in the OS. User chooses a frame size based on this and the function checks and returns available memory (updates in place).
    stream._frames_ref[] = frames_max
    ccall(soundio_outstream_begin_write_ptr, Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), output_stream_ptr, stream._areas_ref, stream._frames_ref)
    actual_frames = stream._frames_ref[]
    # Get the hardware destination pointer
    # Note: unsafe_load(stream._areas_ref[]) returns a SoundIoChannelArea_C
    hardware_ptr = unsafe_load(stream._areas_ref[]).ptr
    # destination_ptr = convert(Ptr{Int32}, unsafe_load(stream._areas_ref[]).ptr)
    # 3. Calculate Copy Logic (Your verified logic)
    remaining_src_frames = layout.total_frames - stream.current_frame
    frames_to_copy = min(actual_frames, remaining_src_frames)
    if stream.is_playing && frames_to_copy > 0
        # Calculate offset in BYTES to match your verified math
        # We use Ptr{UInt8} to ensure + moves by exactly 1 byte per unit
        bytes_per_sample = sizeof(Int32) #TODO:: Make a different version for each datatype.
        source_offset_bytes = stream.current_frame * layout.channels * bytes_per_sample
        total_bytes_to_copy = frames_to_copy * layout.channels * bytes_per_sample
        # Perform the copy using raw byte pointers for maximum safety and speed
        unsafe_copyto!(hardware_ptr, convert(Ptr{UInt8}, layout.data_ptr) + source_offset_bytes, total_bytes_to_copy)
        #=
        src_offset = stream.current_frame * layout.channels * sizeof(Int32)
        unsafe_copyto!(destination_ptr, layout.data_ptr + src_offset, to_copy * layout.channels)
        =#
        stream.current_frame += frames_to_copy
    end
    # 4. Handle Silence / End-of-Buffer
    if frames_to_copy < actual_frames
        # Match your verified silence logic
        silence_frames = actual_frames - frames_to_copy
        silence_offset_bytes = frames_to_copy * layout.channels * sizeof(Int32)
        # Zero-allocation silence fill
        silence_dest = convert(Ptr{Int32}, hardware_ptr + silence_offset_bytes)
        silence_view = unsafe_wrap(Array, silence_dest, silence_frames * layout.channels)
        #=
        silence_offset = to_copy * layout.channels
        silence_view = unsafe_wrap(Array, destination_ptr + (silence_offset * sizeof(Int32)), (actual_frames - to_copy) * layout.channels)
        =#
        #=
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), dest_ptr + silence_offset_bytes, 0, (actual_frames - to_copy) * layout.channels * sizeof(Int32))
        =#
        fill!(silence_view, zero(Int32))
        if stream.current_frame >= layout.total_frames
            stream.is_finished = true
        end
    end
    # 5. Commit to Hardware
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), output_stream_ptr)
    return nothing
end
function realtime_audio_callback(output_stream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint)
    sync::AudioCallbackSynchronizer = get_audio_buffer(output_stream_ptr)
    sync._frames_ref[] = frames_max
    ccall(soundio_outstream_begin_write_ptr, Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), output_stream_ptr, sync._areas_ref, sync._frames_ref)
    if sync._frames_ref[] > 0
        @atomic sync.status = 1 # Signal Julia Worker
        while (@atomic sync.status) != 2
            if !(@atomic sync.is_active) break end
            ccall(:jl_cpu_pause, Cvoid, ())
        end
        @atomic sync.status = 0 # Reset for next cycle
    end
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), output_stream_ptr)
    return nothing
end
const FROZEN_CALLBACK = @cfunction(frozen_audio_callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))
const REALTIME_CALLBACK = @cfunction(realtime_audio_callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))
get_audio_buffer_callback(buffer::FrozenAudioBuffer) = FROZEN_CALLBACK
get_audio_buffer_callback(buffer::AudioCallbackSynchronizer) = REALTIME_CALLBACK
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
function Base.open(device::SoundIODevice, buffer::T, sample_rate::Integer, format::Int32, latency_seconds::Float64 = 3.0) where {T <: SoundIOSynchronizer}
    out_ptr = initialize_sound_stream(device)
    s = unsafe_load(out_ptr) # Load C-struct, update fields
    s.format, s.sample_rate, s.userdata, s.software_latency = Cint(format), Cint(sample_rate), pointer_from_objref(buffer), latency_seconds
    s.write_callback = get_audio_buffer_callback(buffer)
    # s.error_callback = ERROR_CALLBACK (if defined) (Recommended)
    unsafe_store!(out_ptr, s) # Push back to C memory
    # Negotiate hardware
    result = open_sound_stream_unsafe!(out_ptr)
    open_sound_stream_error_check(result)
    # actual_s = unsafe_load(out_ptr) (Optional: Read back the actual achieved latency)
    stream = SoundIOOutStream(out_ptr, s.format, s.sample_rate) #latency_seconds, actual_s.software_latency
    push!(device.streams, stream) 
    return stream
end
function Base.open(device::SoundIODevice, buffer::T, sample_rate::Integer, format::Symbol, latency_seconds::Float64 = 1.0) where {T <: SoundIOSynchronizer}
    if !haskey(SoundIoFormats, format)
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    return open(device, buffer, sample_rate, SoundIoFormats[format], latency_seconds)
end
# 4. Resume existing stream. (Streams persist over context changes)
function reopen!(stream::SoundIOOutStream)
    stream.ptr == C_NULL && error("Cannot reopen a null stream.")
    result = open_sound_stream_unsafe!(stream.ptr)
    open_sound_stream_error_check(result)
    return nothing
end
start!(stream::SoundIOOutStream) = ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
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
function play_audio(audio_data::Matrix{T}, sample_rate::Integer, ctx::SoundIOContext, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32}, T<:Number}
    channels, frames = size(audio_data)
    buffer = FrozenAudioBuffer(pointer(audio_data), frames, channels) # Create our modular "Frozen" structure
    GC.@preserve audio_data buffer begin # Preserve audio data and the buffer object from GC during the C thread's run
        stream = open(device, buffer, sample_rate, format)
        start!(stream)
        #println("🔊 Playback started. Press Ctrl+C to stop.")
        try
            # Main Control Loop
            while !buffer.stream.is_finished
                wait_unsafe(ctx) # wait_events is efficient; it sleeps the thread until an event occurs
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

@inline function get_callbackSyncData(sync::AudioCallbackSynchronizer,channels)
    h_frames::Int = sync._frames_ref[]
    h_ptr = unsafe_load(sync._areas_ref[]).ptr |> Ptr{Int32}
    hw_matrix = unsafe_wrap(Array, h_ptr, (channels, h_frames))# Wrap the C pointer into a julia array.
    return h_frames, hw_matrix
end
