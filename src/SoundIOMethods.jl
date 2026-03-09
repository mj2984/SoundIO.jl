# --- The Audio Callback (Native Thread) ---
#=
function frozen_audio_callback(output_stream_ptr::Ptr{SoundIoOutStream_C}, frames_min::Cint, frames_max::Cint)
    # --- 1. Object Recovery (Zero Allocation) ---
    # We jump directly to the 'userdata' pointer inside the C-struct.
    # This avoids loading the entire 100+ byte struct into Julia.
    userdata_ptr_ptr = convert(Ptr{Ptr{Cvoid}}, output_stream_ptr + SOUNDIO_OUTSTREAM_USERDATA_OFFSET)
    raw_buffer_ptr   = unsafe_load(userdata_ptr_ptr)
    # Assert type so the compiler generates specialized, fast machine code.
    audio_buffer = unsafe_pointer_to_objref(raw_buffer_ptr)::FrozenAudioBuffer
    layout = audio_buffer.layout
    stream = audio_buffer.stream
    # --- 2. Hardware Buffer Negotiation ---
    # Tell libsoundio we want to write up to frames_max.
    stream._frames_ref[] = frames_max
    # This call populates stream._areas_ref with the hardware memory address.
    ccall(soundio_outstream_begin_write_ptr, Cint, 
          (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), 
          output_stream_ptr, stream._areas_ref, stream._frames_ref)
    actual_frames_granted = stream._frames_ref[]
    # Get the starting pointer of the hardware's memory buffer.
    hardware_dest_ptr = unsafe_load(stream._areas_ref[]).ptr
    # --- 3. Memory Transfer (Data Copy) ---
    frames_remaining_in_src = layout.total_frames - stream.current_frame
    frames_to_copy = min(actual_frames_granted, frames_remaining_in_src)
    if stream.is_playing && frames_to_copy > 0
        bytes_per_sample = sizeof(Int32)
        total_channels   = layout.channels
        # Calculate exactly where we are in our source data.
        source_offset_bytes = stream.current_frame * total_channels * bytes_per_sample
        total_bytes_to_copy = frames_to_copy * total_channels * bytes_per_sample
        # Optimized copy (lowers to LLVM memcpy).
        unsafe_copyto!(hardware_dest_ptr, layout.data_ptr + source_offset_bytes, total_bytes_to_copy)
        stream.current_frame += frames_to_copy
    end
    # --- 4. Silence Padding & End-of-Buffer Check ---
    # If the hardware gave us more space than we have data for, we must fill it with silence.
    if frames_to_copy < actual_frames_granted
        silence_frames = actual_frames_granted - frames_to_copy
        silence_offset_bytes = frames_to_copy * layout.channels * sizeof(Int32)
        # Zero-out the remainder to prevent "buffer buzzing" or noise.
        silence_ptr  = convert(Ptr{Int32}, hardware_dest_ptr + silence_offset_bytes)
        silence_size = silence_frames * layout.channels
        # Zero-allocation view and fill.
        fill!(unsafe_wrap(Array, silence_ptr, silence_size), zero(Int32))
        if stream.current_frame >= layout.total_frames
            stream.is_finished = true
        end
    end
    # --- 5. Commit to Hardware ---
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), output_stream_ptr)
    return nothing
end
=#
function frozen_audio_callback(output_stream_ptr::Ptr{SoundIoOutStream_C}, f_min::Cint, f_max::Cint)
    output_stream = unsafe_load(output_stream_ptr)
    buffer = unsafe_pointer_to_objref(output_stream.userdata)::FrozenAudioBuffer
    layout, stream = buffer.layout, buffer.stream
    # _frames_ref is both an input and output.
    # f_max is provided by sound driver which is then passed onto soundio_outstream_begin_write_ptr.
    # It checks and updates this with a number equal to or less than f_max based on available memory.
    stream._frames_ref[] = f_max
    ccall(soundio_outstream_begin_write_ptr, Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), output_stream_ptr, stream._areas_ref, stream._frames_ref)
    actual_frames = stream._frames_ref[]
    destination_ptr = convert(Ptr{Int32}, unsafe_load(stream._areas_ref[]).ptr)
    remaining = layout.total_frames - stream.current_frame
    to_copy = min(actual_frames, remaining)
    if stream.is_playing && to_copy > 0
        src_offset = stream.current_frame * layout.channels * sizeof(Int32)
        unsafe_copyto!(destination_ptr, layout.data_ptr + src_offset, to_copy * layout.channels)
        stream.current_frame += to_copy
    end
    # Handle padding/End-of-Buffer with silence
    if to_copy < actual_frames
        silence_offset = to_copy * layout.channels
        silence_view = unsafe_wrap(Array, destination_ptr + (silence_offset * sizeof(Int32)), (actual_frames - to_copy) * layout.channels)
        fill!(silence_view, zero(Int32))
        
        if stream.current_frame >= layout.total_frames
            stream.is_finished = true
        end
    end
    #=
        silence_offset = to_copy * layout.channels * sizeof(Int32)
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), 
              dest_ptr + silence_offset, 0, (actual_frames - to_copy) * layout.channels * sizeof(Int32))
        
        if stream.current_frame >= layout.total_frames
            stream.is_finished = true
        end
    =#
    ccall(soundio_outstream_end_write_ptr, Cint, (Ptr{Cvoid},), output_stream_ptr)
    return nothing
end#
const FROZEN_CALLBACK = @cfunction(frozen_audio_callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))
# Lifecycle & Check
Base.isopen(ctx::SoundIOContext) = ctx.ptr[] != C_NULL
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
wait_unsafe(ctx::SoundIOContext) = ccall(soundio_wait_events_ptr, Cvoid, (Ptr{Cvoid},), ctx.ptr[])
Base.wait(ctx::SoundIOContext)= isopen(ctx) && wait_unsafe(ctx)
function SoundIOContext(f::Function)
    ctx = SoundIOContext()
    try
        connect!(ctx) # Auto-connect for convenience in do-blocks
        f(ctx)
    finally 
        close(ctx) 
    end
end
function enumerate_devices!(ctx::SoundIOContext)
    # 1. Ensure we have a valid connection
    #connect!(ctx)
    flush_events!(ctx)
    #=
    err = ccall((:soundio_connect, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    err != 0 && error("Connect failed: $err")
    ccall((:soundio_flush_events, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
    =#
    # 2. Refresh our high-level Julia list
    empty!(ctx.devices)
    count = ccall((:soundio_output_device_count, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    def_idx = ccall((:soundio_default_output_device_index, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    for i in 0:(count-1)
        dev_ptr = ccall((:soundio_get_output_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), ctx.ptr[], i)
        # Access C fields via our helper struct to get name/id strings
        c_dev = unsafe_load(convert(Ptr{SoundIoDevice_C}, dev_ptr))
        # New SoundIODevice triggers ccall(:soundio_device_ref) and sets finalizer
        push!(ctx.devices, SoundIODevice(
            dev_ptr, 
            unsafe_string(c_dev.name), 
            unsafe_string(c_dev.id), 
            false,
            i == def_idx
        ))
        # Drop the temporary reference from get_output_device
        ccall((:soundio_device_unref, libsoundio), Cvoid, (Ptr{Cvoid},), dev_ptr)
    end
end
list_devices(ctx::SoundIOContext) = ctx.devices
function initialize_sound_stream(device::SoundIODevice)
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptr)
    out_ptr == C_NULL && error("Failed to create outstream")
    return out_ptr
end
function open_sound_stream_error_check(result::Cint)
    result == 0 && return nothing
    # 1. Get our clean Julia symbol
    err_sym = get(SoundIoErrorMap, result, :UnknownError)
    # 2. Get the official C string for the technical "why"
    c_str_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), result)
    c_msg = c_str_ptr != C_NULL ? unsafe_string(c_str_ptr) : "No message provided by libsoundio."
    # 3. Throw a descriptive error
    error("SoundIO [:$err_sym]: $c_msg (Code: $result)")
end
function open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutStream_C})
    result = ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr)
    return result
end
function Base.open(device::SoundIODevice, buffer::FrozenAudioBuffer, sample_rate::Integer, format::Int32)
    out_ptr = initialize_sound_stream(device)
    # Load C-struct, update fields
    s = unsafe_load(out_ptr)
    s.format, s.sample_rate, s.write_callback, s.userdata = Cint(format), Cint(sample_rate), FROZEN_CALLBACK, pointer_from_objref(buffer) # DIRECT_CALLBACK, pointer_from_objref(state)
    # Recommended: s.error_callback = ERROR_CALLBACK (if defined)
    unsafe_store!(out_ptr, s) # Push back to C
    # Negotiate hardware
    result = open_sound_stream_unsafe!(out_ptr)
    open_sound_stream_error_check(result)
    # Wrap and track
    stream = SoundIOOutStream(out_ptr, s.format, s.sample_rate)
    push!(device.streams, stream) 
    return stream
end
function Base.open(device::SoundIODevice, buffer::FrozenAudioBuffer, sample_rate::Integer, format::Symbol)
    if !haskey(SoundIoFormats, format) # Perform the dictionary lookup
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    return open(device, buffer, sample_rate, SoundIoFormats[format]) # Call the Integer-based method
end
# 4. Resume existing stream. (Streams persist over context changes.)
function reopen!(stream::SoundIOOutStream)
    stream.ptr == C_NULL && error("Cannot reopen a null stream.")
    result = open_sound_stream_unsafe!(stream.ptr)
    open_sound_stream_error_check(result)
    return nothing
end
start!(stream::SoundIOOutStream) = ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr)
#check_soundio_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))
function play_audio(audio_data::Matrix{Int32}, sample_rate::Integer, ctx::SoundIOContext, device::SoundIODevice, format::fmtType) where fmtType <: Union{Symbol,Int32}
    channels, frames = size(audio_data)
    # state = PlaybackState(pointer(audio_data), frames, 0, channels, true)
    buffer = FrozenAudioBuffer(pointer(audio_data), frames, channels) # Create our modular "Frozen" structure
    # Preserve audio data and the buffer object from GC during the C thread's run
    GC.@preserve audio_data buffer begin
        stream = open(device, buffer, sample_rate, format)
        start!(stream)
        #push!(ctx.streams, stream_ptr) # Track for RAII cleanup
        #println("🔊 Playback started. Press Ctrl+C to stop.")
        try
            # Main Control Loop
            while !buffer.stream.is_finished
                # wait_events is efficient; it sleeps the thread until an event occurs
                wait_unsafe(ctx)
                # Small sleep to yield to Julia scheduler for REPL interactivity
                #yield()
            end
        finally
            # Stop stream playback when done or interrupted
            ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
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
#1. The Watcher (Runs in the background)
event_task = @async begin
    while isopen(ctx)
        wait_unsafe!(ctx) # Blocks here at 0% CPU until a hardware event occurs
        put!(event_channel, :hardware_changed) # Notify the rest of the app
    end
end#
# 2. The Playback Loop (Runs in the foreground)
while !buffer.stream.is_finished
    # We don't 'wait' here because we don't want to stop the music 
    # just to listen for a USB plug-in.
    flush_events!(ctx) # Quickly check for errors/unplugs
    sleep(0.01)        # Keep REPL alive for Ctrl+C
end
function enumerate_devices!(ctx::SoundIOContext)
    #def_out = ccall((:soundio_default_output_device_index, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    #def_in  = ccall((:soundio_default_input_device_index, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    count = ccall((:soundio_output_device_count, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    #out_count = ccall((:soundio_output_device_count, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    #for i in 0:(out_count - 1)
    #    dev_ptr = ccall((:soundio_get_output_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Int32), ctx.ptr[], i)
    #    name_ptr = unsafe_load(convert(Ptr{Cstring}, dev_ptr + 16))
    #    push!(ctx.devices, SoundIODevice(dev_ptr, unsafe_string(name_ptr), false, i == def_out))
    #end
    def_idx = ccall((:soundio_default_output_device_index, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[])
    for i in 0:(count-1)
        dev_ptr = ccall((:soundio_get_output_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), ctx.ptr[], i)
        name_ptr = unsafe_load(convert(Ptr{Cstring}, dev_ptr + 16))
        push!(ctx.devices, SoundIODevice(dev_ptr, unsafe_string(name_ptr), false, i == def_idx))
    end
    #in_count = ccall((:soundio_input_device_count, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    #for i in 0:(in_count - 1)
    #    dev_ptr = ccall((:soundio_get_input_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Int32), ctx.ptr[], i)
    #    name_ptr = unsafe_load(convert(Ptr{Cstring}, dev_ptr + 16))
    #    push!(ctx.devices, SoundIODevice(dev_ptr, unsafe_string(name_ptr), true, i == def_in))
    #end
    
    #out_count = ccall((:soundio_output_device_count, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    #in_count = ccall((:soundio_input_device_count, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
    #devices = SoundIODevice[]
    # Process Outputs
    #for i in 0:(out_count-1)
    #    dev_ptr = ccall((:soundio_get_output_device, libsoundio), Ptr{Cvoid}, (Ptr{Cvoid}, Int32), ctx.ptr[], i)
        # Offset 16 is the 'name' pointer in SoundIoDevice (v2.0.0 x64)
    #    name_ptr = unsafe_load(convert(Ptr{Cstring}, dev_ptr + 16))
    #    push!(devices, SoundIODevice(dev_ptr, unsafe_string(name_ptr), false))
        # Note: We don't unref here yet if we want to keep the pointer valid in SoundIODevice
    #end
    #return devices
    #end
end
=#
