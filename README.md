# SoundIO.jl

**SoundIO.jl** aims to provide a Julia native binding to [libsoundio](https://github.com), merging the low-level access of the original C library with the interactivity and rapid development of Julia.

In the delicate balance between performance, power, and API convenience, the scale is tipped closer to the former—as is the case with the original library. However, the features of Julia make it significantly easier to manage resources while still hitting professional-grade performance targets. SoundIO.jl provides high-level safety guides while maintaining enough low-level access for the fine details as required.

## 🚀 Key Features
*   **Zero-Allocation Callbacks**: Optimized memory offsets bypass expensive symbol lookups, allowing C to call Julia without significant overhead.
*   **Threaded Synchronicity**: A custom `AudioCallbackSynchronizer` and `@atomic` status flags bridge the gap between high-priority C audio threads and Julia tasks.
*   **No Manual Setup**: Leverages `libsoundio_jll` for seamless binary management across Windows, macOS, and Linux.

🛠 Quick Start: Playback from RAM
SoundIO.jl makes it easy to stream audio data directly from a Julia Matrix using the high-level play_audio method.

```
using SoundIO

# 1. Prepare your audio data (Stereo Matrix)
fs = 44100
t = 0:1/fs:1
sine = Int32.(round.(sin.(2π * 440 .* t) .* (2^31 - 1)))
audio_data = vcat(sine', sine') 

# 2. Open a Context and Play
SoundIOContext() do ctx
    enumerate_devices!(ctx)
    
    # Select a 'Raw' device for the lowest latency possible
    device = first(filter(d -> !d.is_input && d.is_raw, ctx.devices))
    
    println("🎶 Playing on: $(device.name)")
    play_audio(audio_data, Int(fs), ctx, device, :Int32Little)
end
```
⚡ Advanced: High-Performance Threaded Worker
For real-time synthesis or heavy processing, you can "pin" an audio worker task to a specific CPU thread to prevent interference from the Julia scheduler.

```
sync = AudioCallbackSynchronizer()

# Create a task and stick it to Thread 5 for maximum stability
worker_task = @task audio_streamer_ram_playback(sync, audio_data)
ccall(:jl_set_task_tid, Cvoid, (Any, Int16), worker_task, 5) 
worker_task.sticky = true
schedule(worker_task)

# The C callback will now signal Thread 5 whenever the hardware buffer is ready.
```

🔍 Self-Documenting Interactivity

A core goal of SoundIO.jl is to support the development of code that is self-documenting in nature. By mapping low-level C constants to idiomatic Julia Symbols, your source code remains readable and intent-driven:

*   **Readable Formats**: Use symbols like :Int16Little, :Int32Little, or :Float32Big instead of magic numbers.
*   **Expressive Errors**: Hardware issues are surfaced as descriptive symbols such as :BackendDisconnected or :OpeningDeviceFailed.
*   **Rich REPL Inspection**: Custom show methods provide immediate visual feedback on the state of your audio stack.
```
julia> ctx = SoundIOContext(); connect!(ctx); enumerate_devices!(ctx);
julia> ctx
SoundIOContext(🟢 Connected, 4 Devices, 1 Active Streams)
    1. 🎧 [🔗] Realtek Audio ⭐
      └─ Formats: Int16Little, Int24Little, Int32Little, Float32Little
      └─ Active Streams: 1
    2. 🎤 [  ] USB Microphone
```
📂 Demos & Testing

For a complete example of how to load and play back a high-quality WAV file using the threaded worker pattern, please refer to:
*   **/test/SoundIODemo.jl**: Core logic for streaming from RAM and 24-bit alignment.
*   **/test/SoundIOTest.jl**: Entry point for running the demo on your local machine

🛡 Safety & Implementation

*   **Reference Counting**: SoundIODevice automatically manages C-side reference counts to prevent use-after-free errors.
*   **GC Preservation**: Critical buffers are wrapped in GC.@preserve blocks during playback to ensure the C-thread always has a valid memory address.
*   **Error Handling**: Instead of raw integers, errors are returned as clean Julia symbols (e.g., :BackendDisconnected, :BufferUnderflow, :OutOfMemory).

License

SoundIO.jl: MIT License (c) 2026 mj2984

libsoundio: MIT License (c) 2015 Andrew Kelley
