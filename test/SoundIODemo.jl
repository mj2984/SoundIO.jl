include(raw"../src/SoundIO.jl")
using .SoundIO
# A simple audio streamer that plays from RAM (audio_data).
# Example of pure julia pipeline to interface with SoundIO buffers.
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer, audio_data::Matrix{Int32})
    channels, total_frames = size(audio_data)
    current_frame = 0 
    #=
    bytes_per_sample = sizeof(Int32)
    bytes_per_frame = channels * bytes_per_sample
    src_base_ptr = pointer(audio_data)
    =#
    while (@atomic sync.is_active) && current_frame < total_frames
        while (@atomic sync.status) != 1
            (!(@atomic sync.is_active)) && return
            ccall(:jl_cpu_pause, Cvoid, ())
        end
        h_frames::Int, hw_matrix = get_callbackSyncData(sync,channels)
        rem_frames = total_frames - current_frame
        to_copy = min(h_frames, rem_frames)
        if to_copy > 0
            #=
            src_offset_ptr = convert(Ptr{UInt8}, src_base_ptr) + (current_frame * bytes_per_frame)
            dst_ptr = convert(Ptr{UInt8}, h_ptr)
            unsafe_copyto!(dst_ptr, src_offset_ptr, to_copy * bytes_per_frame)
            =#
            @views copyto!(hw_matrix[:, 1:to_copy], audio_data[:, current_frame+1:current_frame+to_copy])
            if to_copy < h_frames
                #=
                silence_ptr = dst_ptr + (to_copy * bytes_per_frame)
                silence_bytes = (h_frames - to_copy) * bytes_per_frame
                ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), silence_ptr, 0, silence_bytes)
                =#
                @views fill!(hw_matrix[:, to_copy+1:end], Int32(0))
            end
            current_frame += to_copy
        end
        (current_frame >= total_frames) && (@atomic sync.is_active = false)
        @atomic sync.status = 2 
    end
end
# Uses the audio_streamer_ram_playback to manage streaming.
function play_audio_threaded(audio_data::Matrix{Int32}, sample_rate::Integer, ctx::SoundIOContext, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32}}
    sync = AudioCallbackSynchronizer()
    # worker_task = Threads.@spawn run_audio_worker!(sync, audio_data)
    worker_task = @task audio_streamer_ram_playback(sync, audio_data)
    ccall(:jl_set_task_tid, Cvoid, (Any, Int16), worker_task, 5) 
    worker_task.sticky = true
    schedule(worker_task)
    GC.@preserve audio_data sync begin
        stream = open(device, sync, sample_rate, format)
        start!(stream)
        while (@atomic sync.is_active)
            wait_unsafe(ctx) 
            #yield()
        end
        ccall((:soundio_outstream_destroy, libsoundio), Cvoid, (Ptr{Cvoid},), out_ptr)
    end
    wait(worker_task)
    println("Playback finished.")
end
function align_audio_bytes!(data,source_bits::T,destination_format::Symbol) where {T<:Integer}
    if(source_bits == 24 && destination_format == :Int32Little)
        map!(x -> x << 8, data,data)
    end
end
@inline function process_audio(path,destination_format::Symbol)
    # 1. Load native Int32 (24-bit audio in 32-bit container)
    # NOTE:: wavread updated to produce native format (interleaved audio). The raw_layout argument is only available in a fork.
    # raw_layout = true is equivalent to permutedims(audio_data,(2,1)) if audio_data came from raw_layout = false
    audio_data,sample_rate, nbits, opt = wavread(path, format = "native", raw_layout = true)
    align_audio_bytes!(audio_data,nbits,destination_format)
    return audio_data, sample_rate
end
function play_music(path)
    destination_format = :Int32Little
    audio_data,sample_rate = process_audio(sound_file,destination_format)
    SoundIOContext() do ctx
        enumerate_devices!(ctx)
        audio_device = filter(d -> !d.is_input, ctx.devices)[2]
        println("🎶 Playing: $path")
        println("Keys: [p]ause/resume, [s]eek forward 10s, [v]olume down, [q]uit")
        play_audio(audio_data,Int(sample_rate),ctx,audio_device,destination_format)
        #play_audio_threaded(audio_data,Int32(sample_rate),ctx,audio_device,destination_format)
        println("Finished!")
    end
end
#=
function play_with_controls(path,target_fs)
    @inline processed_audio,processed_sample_rate = process_audio(path,target_fs)
    channels, frames = size(processed_audio)
    #state = PlaybackState(pointer(processed_audio), frames, 0, channels, true)
    buffer = FrozenAudioBuffer(pointer(processed_audio), frames, channels)
    GC.@preserve processed_audio buffer begin
        SoundIOContext() do ctx
            enumerate_devices!(ctx)
            device = filter(d -> !d.is_input, ctx.devices)[2]
            stream = open_outstream_direct(device, buffer, Int(processed_sample_rate), :Int32Little)
            
            #println("🎶 Playing: $path")
            #println("Keys: [p]ause/resume, [s]eek forward 10s, [v]olume down, [q]uit")
            
            while !buffer.stream.is_finished
                wait_events(ctx)
                #sleep(0.1) # Main loop is idle, audio runs in background thread
                
                # --- Example Real-Time Interaction ---
                # state.volume = 0.5f0           # Half volume
                # state.is_playing = false       # Pause
                # state.current_frame += 960000  # Seek forward 10 seconds
            end
            #println("Finished!")
        end
    end
end
=#
