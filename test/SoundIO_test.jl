sound_file = raw"sound_file.wav"
enumerate_sound_devices!()
audio_device::SoundIODevice = filter(d -> (!d.is_input) & (d.is_raw), list_sound_devices())[1]
println("🎶 Playing: $sound_file")
audio_data::SampleArray = audioread(sound_file,false) # SampleArray contains information about sample rate.
play_audio(audio_device,audio_data)
println("Finished!")
