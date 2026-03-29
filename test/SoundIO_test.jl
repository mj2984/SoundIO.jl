include(raw"SoundIODemo.jl")
sound_file = raw"sound_file.wav"
enumerate_sound_devices!()
audio_device = filter(d -> (!d.is_input) & (d.is_raw), list_sound_devices())[1]
audio_device = filter(d -> (!d.is_input) & (d.is_raw), ctx.devices)[1]
println("🎶 Playing: $sound_file")
play_music(sound_file,audio_device)
println("Finished!")
