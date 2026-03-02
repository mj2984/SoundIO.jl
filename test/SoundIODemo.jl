include(raw"../src/SoundIO.jl")
using .SoundIO
function play_with_controls(path)
    # 1. Load native Int32 (24-bit audio in 32-bit container)
    y_native, fs = wavread(path, format="native", raw_layout = true)
    # wavread updated to produce native format (interleaved audio)
    channels, frames = size(y_native)
    # 3. Shift to 32-bit
    packed_data = y_native .<< 8
    # 3. Create the Bridge with Controls
    state = PlaybackState(pointer(packed_data), frames, 0, channels, true, 1.0f0)
    # 4. Playback with Safety Preservation
    GC.@preserve packed_data state begin
        SoundIOContext() do ctx
            enumerate_devices!(ctx)
            target = first(filter(d -> !d.is_input && d.is_default, ctx.devices))
            stream = open_outstream_direct(ctx, target, SoundIO.S32LE, Int(fs), state)
            
            println("🎶 Playing: $path")
            println("Keys: [p]ause/resume, [s]eek forward 10s, [v]olume down, [q]uit")
            
            while state.current_frame < state.total_frames
                wait_events(ctx)
                sleep(0.1) # Main loop is idle, audio runs in background thread
                
                # --- Example Real-Time Interaction ---
                # state.volume = 0.5f0           # Half volume
                # state.is_playing = false       # Pause
                # state.current_frame += 960000  # Seek forward 10 seconds
            end
            println("Finished!")
        end
    end
end
