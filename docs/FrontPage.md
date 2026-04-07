# SoundIO.jl
### Transparent, high-performance audio transport for Julia.

**SoundIO.jl** is a high-quality streaming engine built on the `libsoundio` backend. It provides a Julia-native API for direct, low-latency access to audio hardware, designed for developers who need full visibility and precise control over their signal path. 

By merging systems-level control with Julia’s rapid development workflow, SoundIO.jl achieves native-level efficiency within a safe, expressive, and interactive environment.

---

## 🎯 Key Philosophies

### ⚡ Zero-Cost Abstractions
We leverage Julia’s type system to generate optimized, branchless callback functions on the fly. By specializing on your stream's specific parameters at compile-time, the engine eliminates boilerplate and executes with the efficiency of hand-tuned machine procedures, while your code remains readable and Julian.

### 🔍 REPL-First Exploration
Designed for interactive use, SoundIO.jl acts as a text-based device manager. Use the REPL to inspect hardware capabilities—contexts, devices, and formats—with custom pretty-printing and an intuitive, "GUI-like" overview.

### 🛡️ Safe by Construction
From high-level buffer abstractions to managed GC-preservation, the library is engineered so you can leverage peak hardware performance without needing low-level systems programming expertise.

---

## 🚀 Core Features

*   **Transparent & Raw:** Bypasses OS mixing to support raw data formats, from standard PCM to high-precision telemetry.
*   **Performance Focused:** Minimal latency, zero allocations in the hot path, and native blocking waits for zero-CPU idling.
*   **Deterministic Sync:** Multiple synchronization models including:
    *   **Frozen Audio Buffer:** A "Flow" model that turns Julia arrays into managed ring buffers.
    *   **Audio Callback Synchronizer:** A "Reactive" model for the lowest possible latency and live DSP.
*   **Extensible Infrastructure:** Build custom transport layers, lock-free graphs, or industrial telemetry pipes by inheriting from `<:SoundIOSynchronizer`.

---

## 🛠️ Applications

Beyond professional audio, SoundIO.jl serves as a high-performance data transport layer for:
*   **Industrial & Medical:** Low-latency ECG/EEG and sensor telemetry.
*   **Real-time Control:** Deterministic bridges for closed-loop feedback and high-frequency reactive loops.
*   **Prototyping:** Rapidly testing signal processing algorithms in an interactive environment before deployment.

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
shared_data = samplezeros(Sample{2,Q0f15},(buffer_atom_time,sampling_frequency),total_buffer_atoms) # Pre allocate the array for buffering.

input_device, output_device = get_sound_devices()
# Opening streams. This gets connections to a sound device and ensures the device is active. Opening a stream with this API locks the shared_data array from being garbage collected.
input_stream  = open(input_device,  (shared_data, false))
output_stream = open(output_device, (shared_data, false))

Threads.@spawn start_loop(input_stream,output_stream)
# At any moment you could peek into shared_data and see the actual data.
```

2. Playing Wav files
```julia
using SamplesCore, WavNative, SoundIO
function play_audio(device::SoundIODevice, audio_data::SampleArray{T,N,A,R}) where {T<:Union{Number,Sample},N,A,R}
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

sound_file = raw"sound_file.wav"
enumerate_sound_devices!()
audio_device = filter(d -> (!d.is_input) & (d.is_raw), list_sound_devices())[1]
println("🎶 Playing: $sound_file")
audio_data = audioread(sound_file,false) # audio_data is a SampleArray which contains information about sample rate.
play_audio(audio_device,audio_data)
println("Finished!")
```
