include(raw"SoundIODemo.jl")
sound_file = raw"C:\Users\manue\Downloads\01 - Song Sohee - Dear My Lover.wav"
#ctx = SoundIOContext()
#connect!(ctx)
#enumerate_devices!(ctx)
play_music(sound_file)
