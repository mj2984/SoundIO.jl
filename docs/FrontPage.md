# SoundIO.jl

SoundIO.jl is a Julia-native binding to libsoundio, designed for real-time, low-latency audio with a clean, Julian API. It preserves the performance and control of the C library while adding type-safe wrappers, expressive callbacks, and rich REPL inspection.

## Features
- Zero-allocation, type-specialized callbacks
- Fast wait loops and event-driven synchronization
- Julia-native `open`/`close` resource management
- Pretty-printed contexts, devices, and streams
- Cross-platform binaries via `libsoundio_jll`
- Safe by default, with optional raw pointer access

## Quick Example
1. Loopback test.
```julia
using SamplesCore, SoundIO
function get_sound_devices()
    enumerate_sound_devices!() # Gets OS permissions and scans available sound devices
    all_devices = list_sound_devices() # Displays available sound devices
    # Getting raw (unprocessed) devices for input and output. Here it connects to the first numbered device it found.
    input_device  = filter(d -> d.is_input && d.is_raw, all_devices)[1]
    output_device = filter(d -> !d.is_input && d.is_raw, all_devices)[1]
    return input_device,output_device
end

function start_loop(input_stream,output_stream)
    input_sync  = input_stream.sync[].stream::FrozenAudioStream # Synchronizer that notifies status at every buffer atoom crossing.
    # For simplicity we only track the input stream status. If required the output stream status can also be tracked but not part of this example.
    println("🎤 Starting Capture...")
    start!(input_stream) # Starts capturing audio and storing into the buffer
    wait(input_sync) # We wait till it sends the first notification (roughly buffer_atom_time + some δ ahead)
    println("🔊 Starting Playback (Real-Time Loopback)...")
    start!(output_stream) # Starts playing back audio
    try
        exchange::FrozenAudioExchange = @atomic input_sync.exchange
        while exchange.status == CallbackJuliaDone # Poll the status and ensure it is stable
            wait(input_sync)
            exchange = @atomic input_sync.exchange
        end
    finally
        close(input_sync)
        destroy_sound_stream_unsafe(input_stream)
        destroy_sound_stream_unsafe(output_stream)
    end
end

sampling_frequency = 48000
buffer_atom_time = 0.5 # Notifications are sent every buffer_atom_time seconds.
total_buffer_atoms = 10 # It goes through 10 such cyles before looping back. (in many cases 2-3 is sufficient)
shared_data = zeros(Sample{2, Int16}, Int(buffer_atom_time * sampling_frequency), total_buffer_atoms) # Pre allocate the array for buffering.

input_device, output_device = get_sound_devices()
# Opening streams. This gets connections to a sound device and ensures the device is active. Opening a stream with this API locks the shared_data array from being garbage collected.
input_stream  = open(input_device,  (shared_data, false), sampling_frequency)
output_stream = open(output_device, (shared_data, false), sampling_frequency)

Threads.@spawn start_loop(input_stream,output_stream)
# At any moment you could peek into shared_data and see the actual data.
```

2. Playing Wav files
```julia
using SamplesCore, WavNative, SoundIO
function play_audio(audio_data::AbstractArray{T}, sample_rate::Integer, device::SoundIODevice) where {T<:Union{Number,Sample}}
    stream = open(device, (audio_data, false), sample_rate) # The stream captures the audio data from being Garbage collected.
    buffer_stream = stream.sync[].stream::FrozenAudioStream
    start!(stream) #println("🔊 Playback started. Press Ctrl+C to stop.")
    try
        exchange::FrozenAudioExchange = @atomic buffer_stream.exchange
        while exchange.status == CallbackJuliaDone
            wait(buffer_stream)
            exchange = @atomic buffer_stream.exchange
        end
    finally
        close(buffer_stream)
        destroy_sound_stream_unsafe(stream) # Stop stream playback when done or interrupted
        #filter!(s -> s != stream_ptr, ctx.streams)
    end
end

function play_music(sound_file::String,audio_device::SoundIODevice)
    audio_data,sample_rate = audioread(sound_file,false)
    play_audio(audio_data,Int(sample_rate),audio_device)
end

sound_file = raw"sound_file.wav"
enumerate_sound_devices!()
audio_device = filter(d -> (!d.is_input) & (d.is_raw), list_sound_devices())[1]
println("🎶 Playing: $sound_file")
play_music(sound_file,audio_device)
println("Finished!")
```
