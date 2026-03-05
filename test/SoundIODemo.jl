include(raw"../src/SoundIO.jl")
using .SoundIO
@inline function process_audio(sound_file)
    # 1. Load native Int32 (24-bit audio in 32-bit container)
    # wavread updated to produce native format (interleaved audio)
    y,fs, nbits, opt = wavread(path, format="native", raw_layout = true)
    processed_audio = y .<< 8
    processed_sample_rate = fs
    return processed_audio, processed_sample_rate
end
function play_music(sound_file)
    audio_data,sample_rate = process_audio(sound_file)
    SoundIOContext() do ctx
        enumerate_devices!(ctx)
        audio_device = filter(d -> !d.is_input, ctx.devices)[2]
        println("🎶 Playing: $sound_file")
        println("Keys: [p]ause/resume, [s]eek forward 10s, [v]olume down, [q]uit")
        play_audio(audio_data,Int(sample_rate),ctx,audio_device,:Int32Little)
        println("Finished!")
    end
end
function play_with_controls(path)
    @inline processed_audio,processed_sample_rate = process_audio(path)
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
                sleep(0.1) # Main loop is idle, audio runs in background thread
                
                # --- Example Real-Time Interaction ---
                # state.volume = 0.5f0           # Half volume
                # state.is_playing = false       # Pause
                # state.current_frame += 960000  # Seek forward 10 seconds
            end
            #println("Finished!")
        end
    end
end
