include(raw"../src/SoundIO.jl")
using .SoundIO
using WAV
using PtrArrays
# A simple audio streamer that plays from RAM (audio_data).
# Example of pure julia pipeline to interface with SoundIO buffers.
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T, Channels}, audio_data::Matrix{T}) where {T, Channels}
    total_frames::Int = size(audio_data, 2)
    #=
    current_frame::Int = 0
    streaming_state::Symbol = :completed
    =#
    current_frame::Int = 0
    while current_frame < total_frames
        #=
        res::Union{Symbol,Matrix{T}} = acquire_sound_buffer(sync)
        if res isa Symbol
            streaming_state = res
            break
        end
        curr_buf::Matrix{T} = res
        buf_frames::Int = size(curr_buf, 2)
        rem_frames::Int = total_frames - current_frame
        to_copy::Int = min(buf_frames, rem_frames)
        @views copyto!(curr_buf[:, 1:to_copy], audio_data[:, current_frame+1:current_frame+to_copy])
        if to_copy < buf_frames
            @views fill!(curr_buf[:, to_copy+1:end], zero(T))
        end
        =#
        dst_ptr, buf_frames = acquire_sound_buffer_ptr(sync)
        dst_ptr == C_NULL && break
        to_copy = min(buf_frames, total_frames - current_frame)
        src_ptr = pointer(audio_data, (current_frame * Channels) + 1)
        unsafe_copyto!(dst_ptr, src_ptr, to_copy * Channels)
        if to_copy < buf_frames
            silence_ptr = dst_ptr + (to_copy * Channels * sizeof(T))
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), silence_ptr, 0, (buf_frames - to_copy) * Channels * sizeof(T))
        end
        current_frame += to_copy
        if(current_frame < total_frames)
            release_sound_buffer(sync)
        end
    end
    halt_sound_buffer(sync)
    #=
    if(streaming_state == :completed)
        halt_sound_buffer(sync)
    end
    return streaming_state
    =#
end
# Uses the audio_streamer_ram_playback to manage streaming.
function play_audio_threaded(audio_data::Matrix{T}, sample_rate::Integer, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32},T}
    stream = open(device, T, size(audio_data, 1), sample_rate, format)
    sync = stream.sync[]
    # worker_task = Threads.@spawn run_audio_worker!(sync, audio_data)
    worker_task = @task audio_streamer_ram_playback(sync, audio_data)
    ccall(:jl_set_task_tid, Cvoid, (Any, Int16), worker_task, 5) 
    worker_task.sticky = true
    schedule(worker_task)
    GC.@preserve audio_data begin
        start!(stream)
        while (s = @atomic sync.message).status > 0
            wait_unsafe(device)
            #yield()
        end
        destroy_sound_stream_unsafe(stream)
    end
    wait(worker_task)
    println("Playback finished.")
end
function align_audio_bytes!(data,source_bits::T,destination_format::Symbol) where {T<:Integer}
    if(source_bits == 24 && destination_format == :Int32Little)
        map!(x -> x << 8, data,data)
    elseif(source_bits == 16 && destination_format == :Int32Little)
        map!(x -> x << 16, data,data)
    end
end
@inline function process_audio(path)
    audio_data,sample_rate, nbits, opt = wavread(path, format = "native", raw_layout = true)
    if(nbits > 16)
        destination_format = :Int32Little
        align_audio_bytes!(audio_data,nbits,destination_format)
    else
        destination_format = :Int16Little
    end
    return audio_data, sample_rate, destination_format
end
function play_music(path)
    audio_data,sample_rate,destination_format::Symbol = process_audio(sound_file)
    SoundIOContext() do ctx
        enumerate_devices!(ctx)
        audio_device = filter(d -> (!d.is_input) & (d.is_raw), ctx.devices)[1]
        println("🎶 Playing: $path")
        println("Keys: [p]ause/resume, [s]eek forward 10s, [v]olume down, [q]uit")
        play_audio(audio_data,Int(sample_rate),audio_device,destination_format)
        #play_audio_threaded(audio_data,Int32(sample_rate),audio_device,destination_format)
        println("Finished!")
    end
end
#1. The Watcher (Runs in the background)
#=
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
=#
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
