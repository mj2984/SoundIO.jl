include(raw"SoundIODemo.jl")
sound_file = raw"sound_file.wav"
#ctx = SoundIOContext()
#connect!(ctx)
#enumerate_devices!(ctx)
play_music(sound_file)
