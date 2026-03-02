# --- The Direct C Callback ---
function direct_callback(os_ptr::Ptr{SoundIoOutStream_C}, f_min::Cint, f_max::Cint)
    os = unsafe_load(os_ptr)
    # Recover our Julia object from the userdata pointer address
    state = unsafe_pointer_to_objref(os.userdata)::PlaybackState
    
    areas_ref = Ref{Ptr{SoundIoChannelArea_C}}()
    frames_to_fill = Ref{Cint}(f_max)
    ccall((:soundio_outstream_begin_write, libsoundio), Cint, 
          (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), os_ptr, areas_ref, frames_to_fill)

    actual_frames = frames_to_fill[]
    dest_ptr = convert(Ptr{Int32}, unsafe_load(areas_ref[]).ptr)
    
    # Logic for Playback and Pause
    frames_remaining = state.total_frames - state.current_frame
    to_copy = min(actual_frames, frames_remaining)
    
    if state.is_playing && to_copy > 0
        src_ptr = state.data_ptr + (state.current_frame * state.channels * sizeof(Int32))
        
        # Apply Volume and Copy
        if state.volume >= 0.99 # Optimization for full volume
            unsafe_copyto!(dest_ptr, src_ptr, to_copy * state.channels)
        else
            # Simple software volume mixing
            for j in 0:(to_copy * state.channels - 1)
                sample = unsafe_load(src_ptr, j + 1)
                unsafe_store!(dest_ptr, round(Int32, sample * state.volume), j + 1)
            end
        end
        state.current_frame += to_copy
        
        # Fill remainder with silence if song ends
        if to_copy < actual_frames
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), 
                  dest_ptr + (to_copy * state.channels * 4), 0, (actual_frames - to_copy) * state.channels * 4)
        end
    else
        # Paused or End of Song: Silence
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), dest_ptr, 0, actual_frames * state.channels * 4)
    end

    ccall((:soundio_outstream_end_write, libsoundio), Cint, (Ptr{Cvoid},), os_ptr)
    return nothing
end

const DIRECT_CALLBACK = @cfunction(direct_callback, Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint))

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

function open_outstream_direct(ctx::SoundIOContext, device::SoundIODevice, format::SoundIoFormat, rate::Integer, state::PlaybackState)
    out_ptr = ccall((:soundio_outstream_create, libsoundio), Ptr{SoundIoOutStream_C}, (Ptr{Cvoid},), device.ptr)
    s = unsafe_load(out_ptr)
    s.format, s.sample_rate, s.write_callback, s.userdata = Cint(format), Cint(rate), DIRECT_CALLBACK, pointer_from_objref(state)
    unsafe_store!(out_ptr, s)
    ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)
    ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), out_ptr)
    return SoundIOOutStream(out_ptr, device, format, Cint(rate))
end
function wait_events(ctx::SoundIOContext, wait_time::Real = 1.0)
    ctx.ptr[] == C_NULL && return
    start_time = time()
    while (time() - start_time) < wait_time
        ccall((:soundio_wait_events, libsoundio), Cvoid, (Ptr{Cvoid},), ctx.ptr[])
        sleep(0.01) # Yield to Julia's task scheduler
    end
end
