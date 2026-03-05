# --- The Direct C Callback ---
function frozen_audio_callback(os_ptr::Ptr{SoundIoOutStream_C}, f_min::Cint, f_max::Cint)
    # Recover our Julia "Frozen" object
    os = unsafe_load(os_ptr)
    buffer = unsafe_pointer_to_objref(os.userdata)::FrozenAudioBuffer
    
    lay = buffer.layout
    st  = buffer.stream

    # 1. Ask Hardware for buffer space
    st._frames_ref[] = f_max
    ccall(soundio_outstream_begin_write_ptr, Cint, 
          (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), 
          os_ptr, st._areas_ref, st._frames_ref)

    actual_frames = st._frames_ref[]
    dest_ptr = convert(Ptr{Int32}, unsafe_load(st._areas_ref[]).ptr)

    # 2. Logic: How much "Frozen" data to copy?
    remaining = lay.total_frames - st.current_frame
    to_copy = min(actual_frames, remaining)

    if st.is_playing && to_copy > 0
        src_offset = st.current_frame * lay.channels * sizeof(Int32)
        unsafe_copyto!(dest_ptr, lay.data_ptr + src_offset, to_copy * lay.channels)
        st.current_frame += to_copy
    end

    # 3. Handle End-of-Buffer and Silence
    if to_copy < actual_frames
        silence_offset = to_copy * lay.channels * sizeof(Int32)
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), 
              dest_ptr + silence_offset, 0, (actual_frames - to_copy) * lay.channels * sizeof(Int32))
        
        if st.current_frame >= lay.total_frames
            st.is_finished = true
        end
    end

    ccall((:soundio_outstream_end_write, libsoundio), Cint, (Ptr{Cvoid},), os_ptr)
    return nothing
end

const FROZEN_CALLBACK = @cfunction(frozen_audio_callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))

function Base.close(ctx::SoundIOContext)
    if ctx.ptr[] != C_NULL
        # Cleanup streams first
        for s in ctx.streams
            ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), s.ptr)
        end
        empty!(ctx.streams)
        empty!(ctx.devices)
        # Cleanup Context
        ccall((:soundio_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
        ctx.ptr[] = C_NULL
        #println("🧹 SoundIO Resources Released.")
    end
end
function SoundIOContext(f::Function)
    ctx = SoundIOContext()
    try f(ctx) finally close(ctx) end
end
Base.isopen(ctx::SoundIOContext) = ctx.ptr[] != C_NULL
function connect!(ctx::SoundIOContext)
    if(isopen(ctx))
        err = ccall((:soundio_connect, libsoundio), Int32, (Ptr{Cvoid},), ctx.ptr[])
        err != 0 && error("Connect failed: ", err)
        ccall((:soundio_flush_events, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
    else
        error("Attempted to use a closed SoundIOContext")
    end
end
function enumerate_devices!(ctx::SoundIOContext)
    # Get Default Indices
    connect!(ctx)
    empty!(ctx.devices)
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
list_devices(ctx::SoundIOContext) = ctx.devices

#=
function open_outstream_direct(device::SoundIODevice, format::SoundIoFormat, rate::Integer, state::PlaybackState)
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptr)
    s = unsafe_load(out_ptr)
    s.format, s.sample_rate, s.write_callback, s.userdata = Cint(format), Cint(rate), DIRECT_CALLBACK, pointer_from_objref(state)
    unsafe_store!(out_ptr, s)
    ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)
    ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)
    return SoundIOOutStream(out_ptr, device, format, Cint(rate))
end
=#
#=
function open_outstream_direct(device::SoundIODevice, buffer::FrozenAudioBuffer, rate::Integer, format::Integer)
    # Create the C-side stream object
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptr)
    out_ptr == C_NULL && error("Failed to create outstream")

    # 1. Map Julia "Frozen" settings to C
    s = unsafe_load(out_ptr)
    s.format = Cint(format)#Cint(SoundIO.S32LE) # Matches your wavread logic
    s.sample_rate = Cint(rate)
    s.write_callback = FROZEN_CALLBACK
    s.userdata = pointer_from_objref(buffer) # The "Hand-off"
    
    # 2. Add Error/Underflow hooks (Optional but recommended)
    # s.underflow_callback = @cfunction(...) 
    
    unsafe_store!(out_ptr, s)

    # 3. Open and Start (with Error Checking)
    check_soundio_err(ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))
    check_soundio_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))

    return out_ptr
end
=#
# Method 1: The "Engine" (Handles the C-calls using raw Integers)
function open_outstream_direct(device::SoundIODevice, buffer::FrozenAudioBuffer, rate::Integer, format::Integer)
    # Create the C-side stream object
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptr)
    out_ptr == C_NULL && error("Failed to create outstream")

    # 1. Map Julia "Frozen" settings to C
    s = unsafe_load(out_ptr)
    s.format = Cint(format) 
    s.sample_rate = Cint(rate)
    s.write_callback = FROZEN_CALLBACK
    s.userdata = pointer_from_objref(buffer) # The "Hand-off" to Julia object
    
    # Update the C-struct in memory
    unsafe_store!(out_ptr, s)

    ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)
    ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)

    # 2. Open and Start (with Error Checking)
    #check_soundio_err(ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))
    #check_soundio_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr))

    #return out_ptr
    return SoundIOOutStream(out_ptr, device, format, Cint(rate))
end

# Method 2: The "Facade" (Converts Symbols to Integers)
function open_outstream_direct(device::SoundIODevice, buffer::FrozenAudioBuffer, rate::Integer, format::Symbol)
    # Perform the dictionary lookup
    if !haskey(SoundIoFormats, format)
        error("Unknown SoundIO format: :$format. Available: $(keys(SoundIoFormats))")
    end
    
    # Call the Integer-based method
    return open_outstream_direct(device, buffer, rate, SoundIoFormats[format])
end
wait_events(ctx::SoundIOContext) = ccall(soundio_wait_events_ptr, Cvoid, (Ptr{Cvoid},), ctx.ptr[])
function wait_events(ctx::SoundIOContext, wait_time::Real = 1.0)
    ctx.ptr[] == C_NULL && return
    start_time = time()
    while (time() - start_time) < wait_time
        ccall((:soundio_wait_events, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
        sleep(0.01) # Yield to Julia's task scheduler
    end
end
#=
@inline function play_audio(audio_data,sample_rate,ctx,audio_device)
    channels, frames = size(audio_data)
    state = PlaybackState(pointer(audio_data), frames, 0, channels, true)
    GC.@preserve audio_data state ctx audio_device begin
        stream = open_outstream_direct(audio_device, SoundIO.S32LE, Int(sample_rate), state)
        while state.current_frame < state.total_frames
            wait_events(ctx)
            sleep(0.1) # Main loop is idle, audio runs in background thread
        end
    end
end
=#
function play_audio(audio_data::Matrix{Int32}, sample_rate::Integer, ctx::SoundIOContext, device::SoundIODevice, format::fmtType) where fmtType <: Union{Symbol,Int32}
    channels, frames = size(audio_data)
    
    # Create our modular "Frozen" structure
    buffer = FrozenAudioBuffer(pointer(audio_data), frames, channels)
    
    # Preserve audio data and the buffer object from GC during the C thread's run
    GC.@preserve audio_data buffer begin
        stream = open_outstream_direct(device, buffer, sample_rate, format)
        #push!(ctx.streams, stream_ptr) # Track for RAII cleanup
        
        #println("🔊 Playback started. Press Ctrl+C to stop.")
        
        try
            # Main Control Loop
            while !buffer.stream.is_finished
                # wait_events is efficient; it sleeps the thread until an event occurs
                wait_events(ctx)
                # Small sleep to yield to Julia scheduler for REPL interactivity
                yield()
            end
        finally
            # Stop stream playback when done or interrupted
            ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), stream.ptr)
            #filter!(s -> s != stream_ptr, ctx.streams)
        end
    end
    #println("✅ Playback finished.")
end
