sound_file = raw"sound_file.wav"
enumerate_sound_devices!()
audio_device::SoundIODevice = filter(d -> (!d.is_input) & (d.is_raw), list_sound_devices())[1]
println("🎶 Playing: $sound_file")
audio_data::DomainArray = audioread(sound_file,false) # SampleArray contains information about sample rate.
audio_view = view(audio_data,0:10) # range provided in domain axis. Here it provides the first 10 seconds.
play_audio(audio_device,audio_view)
println("Finished!")
