using Base.Threads
function run_audio_worker!(sync::AudioCallbackSynchronizer, audio_data::Matrix{Int32})
    chan::Int32 = Int32(size(audio_data, 1))
    total_src::Int64 = Int64(size(audio_data, 2))
    src_ptr::Ptr{Int32} = pointer(audio_data)
    current_frame::Int64 = 0 
    while (@atomic sync.is_active) && current_frame < total_src
        while (@atomic sync.status) != 1
            if !(@atomic sync.is_active) return end
            ccall(:jl_cpu_pause, Cvoid, ())
        end
        h_frames::Int = sync._frames_ref[]
        areas_ptr = sync._areas_ref[]
        first_area = unsafe_load(areas_ptr)
        h_ptr = convert(Ptr{Int32}, first_area.ptr)
        rem_frames = total_src - current_frame
        to_copy = min(h_frames, rem_frames)
        if to_copy > 0
            copy_samples!(h_ptr, src_ptr, current_frame, to_copy, h_frames, chan)
            current_frame += to_copy
        end
        if current_frame >= total_src
            @atomic sync.is_active = false
        end
        @atomic sync.status = 2 
    end
end
function copy_samples!(hw_ptr::Ptr{Int32}, src_ptr::Ptr{Int32}, start_frame::Int64, frames_to_copy::Int64, total_hw_frames::Int, channels::Int32)
    bytes_per_frame = channels * 4
    src_offset = start_frame * bytes_per_frame
    copy_bytes = frames_to_copy * bytes_per_frame
    unsafe_copyto!(convert(Ptr{UInt8}, hw_ptr), convert(Ptr{UInt8}, src_ptr) + src_offset, copy_bytes)
    if frames_to_copy < total_hw_frames
        silence_bytes = (total_hw_frames - frames_to_copy) * bytes_per_frame
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), hw_ptr + copy_bytes, 0, silence_bytes)
    end
    return nothing
end
function play_audio_threaded(audio_data::Matrix{Int32}, sample_rate::Integer, ctx::SoundIOContext, device::SoundIODevice, format::Int32)
    sync = AudioCallbackSynchronizer()
    worker_task = Threads.@spawn run_audio_worker!(sync, audio_data)
    GC.@preserve audio_data sync begin
        stream = open(device, sync, sample_rate, format)
        start!(stream)
        while (@atomic sync.is_active)
            wait_unsafe(ctx) 
            yield()
        end
        ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), out_ptr)
    end
    wait(worker_task)
    println("Playback finished.")
end
#=
function start_realtime_processor(f::Function, buffer::RealtimeAudioBuffer)
    synchronizer, channels= buffer.synchronizer, buffer.channels
    # Spawn to a background thread
    Threads.@spawn begin
        try
            while (@atomic sync.is_active)
                wait(sync.request_ready) # Wait for LibSoundIO signal
                # Zero-copy pointer wrap: single memory access
                ptr = @atomic sync.hardware_ptr
                frames = @atomic sync.frames_available
                audio_view = unsafe_wrap(Array, ptr, frames * channels)
                # USER LOGIC: f(view, frame_count)
                f(audio_view, Int64(frames))
                # Signal C-thread that we are finished
                notify(sync.processing_done)
            end
        catch e
            @error "Realtime Audio Task Failed" exception=e
        end
    end
end
=#
