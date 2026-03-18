include(raw"../src/SoundIO.jl")
using .SoundIO
using WAV
using PtrArrays
# A simple audio streamer that plays from RAM (audio_data).
# Example of pure julia pipeline to interface with SoundIO buffers.
@inline function audio_streamer_ram_playback_base!(current_buffer::Matrix{T},audio_data_remaining::AbstractMatrix{T}) where {T}
    buffer_frames::Int = size(current_buffer, 2)
    to_copy::Int = min(buffer_frames, size(audio_data_remaining,2))
    if to_copy > 0
        #=
        src_offset_ptr = convert(Ptr{UInt8}, src_base_ptr) + (current_frame * bytes_per_frame)
        dst_ptr = convert(Ptr{UInt8}, h_ptr)
        unsafe_copyto!(dst_ptr, src_offset_ptr, to_copy * bytes_per_frame)
        =#
        @views copyto!(current_buffer[:, 1:to_copy], audio_data[:, 1:to_copy])
        if to_copy < buffer_frames
            #=
            silence_ptr = dst_ptr + (to_copy * bytes_per_frame)
            silence_bytes = (buffer_frames - to_copy) * bytes_per_frame
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), silence_ptr, 0, silence_bytes)
            =#
            @views fill!(current_buffer[:, to_copy+1:end], zero(T))
        end
        #current_frame += to_copy
    end
    return to_copy
    #release_sound_buffer(sync)
end
function audio_streamer_ram_playback_base!(buffer_error_enum::Int8,audio_data::AbstractMatrix{T}) where {T}
    return Int(buffer_error_enum)
end
#=
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T,channels}, audio_data::Matrix{T}) where {T,channels}
    total_frames = size(audio_data, 2)
    current_frame_offset::Int = 0
    #=
    bytes_per_sample = sizeof(Int32)
    bytes_per_frame = channels * bytes_per_sample
    src_base_ptr = pointer(audio_data)
    =#
    while(current_frame_offset < total_frames)
        current_buffer = acquire_sound_buffer(sync)
        copied_or_error::Int  = audio_streamer_ram_playback_base!(current_buffer,view(audio_data,current_frame_offset+1:total_frames))
        if(copied_or_error > 0)
            current_frame_offset += copied_or_error
            release_status::Int8 = ifelse(current_frame_offset==total_frames,CallbackInactive,CallbackJuliaDone)
            release_sound_buffer(sync,release_status)
        else
            # Hardware signaled a stop/error via Int8
            # throw error
        end
    end
end
=#
#=
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T}, audio_data::Matrix{T}) where T
    total_frames::Int = size(audio_data, 2)
    current_frame::Int = 0
    streaming_state::Symbol = :completed
    while current_frame < total_frames
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
        current_frame += to_copy
        if(current_frame < total_frames)
            release_sound_buffer(sync)
        end
    end
    if(streaming_state == :completed)
        halt_sound_buffer(sync)
    end
    return streaming_state
end
=#
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T, Channels}, audio_data::Matrix{T}) where {T, Channels}
    total_frames = size(audio_data, 2)
    current_frame = 0
    
    while current_frame < total_frames
        # Get raw pointer instead of a Matrix object
        dst_ptr, buf_frames = acquire_sound_buffer_ptr(sync)
        dst_ptr == C_NULL && break # Stream was stopped
        
        to_copy = min(buf_frames, total_frames - current_frame)
        
        # Calculate source location
        # Since audio_data is a Matrix, we get a pointer to the start of the 'current_frame' column
        src_ptr = pointer(audio_data, (current_frame * Channels) + 1)
        
        # Blazing fast copy
        unsafe_copyto!(dst_ptr, src_ptr, to_copy * Channels)
        
        # Zero out remainder if necessary
        if to_copy < buf_frames
            silence_ptr = dst_ptr + (to_copy * Channels * sizeof(T))
            ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), 
                  silence_ptr, 0, (buf_frames - to_copy) * Channels * sizeof(T))
        end
        
        current_frame += to_copy
        release_sound_buffer(sync)
    end
    halt_sound_buffer(sync)
end
# Uses the audio_streamer_ram_playback to manage streaming.
function play_audio_threaded(audio_data::Matrix{T}, sample_rate::Integer, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32},T}
    stream = open(device, T, size(audio_data, 1), sample_rate, format)
    sync = stream.sync
    # worker_task = Threads.@spawn run_audio_worker!(sync, audio_data)
    worker_task = @task audio_streamer_ram_playback(sync, audio_data)
    ccall(:jl_set_task_tid, Cvoid, (Any, Int16), worker_task, 5) 
    worker_task.sticky = true
    schedule(worker_task)
    GC.@preserve audio_data begin
        start!(stream)
        while (s = @atomic sync.status) > 0
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
