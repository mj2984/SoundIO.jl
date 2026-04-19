sound_file = raw"sound_file.wav"
enumerate_devices!(sounddevices)
audio_device::SoundIODevice = list_devices(sounddevices).outputs[1]
layout = audio_device.layouts[1]
audio_device_configuration = SoundIODeviceConfiguration(audio_device,layout)
println("🎶 Playing: $sound_file")
audio_data::DomainArray = audioread(sound_file,false) # SampleArray contains information about sample rate.
audio_view = view(audio_data,0:10) # range provided in domain axis. Here it provides the first 10 seconds.
play_audio(audio_device_configuration,audio_data)
println("Finished!")
