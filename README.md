# SoundIO.jl
**Transparent, high-performance audio transport.**

**SoundIO.jl** is a high-quality streaming engine built on the robust `libsoundio` backend. It provides a Julia-native API for direct, low-latency access to your audio hardware, designed for developers who need full visibility and precise control over their signal path. By merging the surgical control of a systems-level interface with Julia’s rapid development workflow, you can achieve native-level efficiency within a safe, expressive, and interactive environment.

---

## 🎯 Philosophy: Zero-Cost Abstractions
SoundIO.jl lets you **have your cake and eat it too**: achieve maximum performance through code that is self-documenting.

*   **Compile-Time Specialization:** We leverage Julia’s type system to generate optimized branchless callback functions on the fly. The engine generates optimal instructions by specializing on your stream's parameters, annihilating boilerplate by statically resolving configurations from a single, shared codebase. This allows your code to read like documentation while executing with the efficiency of hand-tuned machine procedures.
*   **Interactive Exploration:** Designed for the REPL, the library acts like a text-based device manager. Custom pretty-printing and emojis provide a "GUI-like" overview of hardware capabilities—contexts, devices, and formats—as easily as inspecting a local variable.
*   **Safe by Construction:** A stable, high-level buffer abstraction is provided for general use, but even custom implementations benefit from Julia-native abstractions for callbacks and optional managed GC-preservation. This design allows a Julia developer to leverage peak hardware performance without needing low-level systems programming expertise.

---

## 🚀 Why SoundIO.jl?

SoundIO.jl offers transparent audio hardware access, bypassing OS mixing to support raw data formats from PCM to high-precision telemetry. Engineered for performance, it features minimal latency, zero allocations in the hot path, and safe abstractions for low-level resource management.

*   **Transparent & Raw:** Drive your hardware exactly as intended. We ensure no hidden OS "magic" or resampling interferes with your signal path.¹
*   **Performance First:** Internal buffers and synchronizers are designed for minimal latency and zero allocations in the hot path.
*   **Intuitive & Julian:** A professional systems-level API providing safety and symmetric code reuse as a zero-cost abstraction, featuring rich REPL pretty-printing and Symbol-based error handling.
*   **Extensible by Design:** Whether using the highly customizable built-in **Frozen Audio Buffer** or defining a custom transport layer using **`<:SoundIOSynchronizer`**, the infrastructure is built to be extended without sacrificing performance. Our type-specialized pipeline allows you to transform normal Julia code into high-performance callbacks for tasks like signal processing and real-time data packing.

> <sup>1</sup> *Transparency is guaranteed for 'Raw' devices; behavior on non-raw devices depends on the OS backend.*

---

## 🧱 Core Synchronization Mechanisms
SoundIO.jl provides highly customizable, bidirectional mechanisms for both ends of the streaming spectrum, while allowing users to define their own custom solutions if required.

1.  **Frozen Audio Buffer (The "Flow" Model)**: A unique mechanism that turns a standard Julia array into a managed ring buffer with customizable synchronization atoms. The engine streams/acquires the data autonomously, only notifying the user at atom boundaries or if an error occurs—allowing you to focus on signal synthesis/analysis in peace, trusting the engine to handle the delivery.
    *   **Snapshots:** Provides atomic progress updates to the Julia task, enabling you to adapt to hardware consumption rates with minimal "peeking" at the callback state.
    *   **Automatic Safety:** Buffers are kept alive (GC-safe) automatically for the lifetime of the stream.
    *   **Customizable Boundaries:** Synchronization atoms are intelligently inferred from your array dimensions to match your application's logic.

2.  **Audio Callback Synchronizer (The "Reactive" Model)**: Engineered for the lowest possible latency, this model acts as a bridge that notifies a Julia task for every single hardware callback. This is ideal for live capture/synthesis, reactive DSP, or any scenario where you must respond to the hardware in real-time.

3.  **Custom Synchronizers**: The architecture is designed for infinite extensibility. By inheriting from `SoundIOSynchronizer` and defining a custom callback method, you can build specialized transport layers that benefit from the library's optimized, elegantly symmetric and type-specialized compilation pipeline.

The library offers versatile synchronization methods for both system-level event handling and its built-in streaming mechanisms. System-level events like `wait(device)` or `wait(context)` utilize a **native blocking wait** for zero-CPU idling during system changes. The provided synchronizers for audio streams reflect specialized performance philosophies: the **Frozen Audio Buffer** uses **event-driven notifications** for efficient task sleeping, while the **Audio Callback Synchronizer** employs **deterministic spin-waiting** to bypass scheduler overhead—both of which serve as references for users implementing custom solutions.

---

### 🧩 Extensible Stream Framework

SoundIO.jl stays close to a minimal, high-performance philosophy, serving as a robust foundation for building high-level abstractions. By leveraging multiple dispatch and a type-specialized pipeline, the architecture makes it trivial to extend the engine for:

*   **Custom Infrastructure:** Lock-free ring buffers, audio graphs, and complex DSP pipelines.
*   **Reactive Processors:** Asynchronous, task-based processors and custom callback generators.

Beyond audio, SoundIO.jl acts as a high-performance synchronous data transport layer. Using **Exclusive Mode** provides a transparent pipe that bypasses OS mixers—making it an ideal transport for:

*   **Industrial & Medical:** Biomedical signals (ECG/EEG) and industrial sensor telemetry.
*   **Low-Latency Command & Control:** A deterministic bridge for closed-loop feedback and other latency-sensitive applications. By synchronizing input and output within Julia's task ecosystem, the engine enables reactive, high-frequency real-time loops.

---

## 📦 Quick Start

The following example demonstrates a **deterministic, bidirectional loopback** using the **Frozen Audio Buffer** infrastructure. It showcases how a single pre-allocated array acts as a shared memory bridge between input and output streams with zero-cost overhead.

### 🏗️ How it Works
1.  **Shared Memory Bridge**: A 2D array of `Sample{2, Int16}` serves as the central transport. In this "Flow" model, the input hardware writes to the array while the output hardware reads from it in parallel.
2.  **Symmetric Initialization**: Both streams are opened using the same unified API. The library automatically handles memory anchoring to ensure `shared_data` remains GC-safe while the hardware callbacks are active.
3.  **Phase Alignment**: By starting the capture device first and using `wait(input_sync)` to catch the first "atom" notification, the system ensures the output buffer is primed with recorded data before playback begins.
4.  **Async Control**: The loop runs in a spawned task, allowing the main Julia session to remain interactive. Because the transport is direct, you can "peek" into `shared_data` in real-time to inspect or process the signal without interrupting the hardware clock.

### 📦 Example Code

1. Loopback test.
```julia
using SamplesCore, SoundIO
get_audio_sample_rate(audio_data::AbstractDomainArray{T,N}) where {T,N} = (T <: Sample) ? interpret_rate(rate(audio_data,1)) : interpret_rate(rate(audio_data,2))
function get_sound_devices(shared_data::AbstractDomainArray{T,N}) where {T,N}
    enumerate_devices!(sound_devices) # Gets OS permissions and scans available sound devices
    all_devices = list_devices(sound_devices) # Displays available sound devices
    # Getting raw (unprocessed) devices for input and output. Here it connects to the first numbered device it found.
    input_device,output_device = all_devices.inputs[1], all_devices.outputs[1]
    input_layout,output_layout = input_device.layouts[1], output_device.layouts[1]
    sample_rate = get_audio_sample_rate(shared_data)
    return SoundDeviceConfiguration(input_device,input_layout,sample_rate,T),SoundDeviceConfiguration(output_device,output_layout,sample_rate,T)
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

sampling_frequency = TypedDomainSpace{48000}()
buffer_atom_time = 0.1 # Notifications are sent every buffer_atom_time seconds.
total_buffer_atoms = 10 # It goes through 10 such cyles before looping back. (in many cases 2-3 is sufficient)
shared_data = domainzeros(to_sample_space,Sample{2,Q0f15},(buffer_atom_time,relativeorigin,sampling_frequency),total_buffer_atoms) # Pre allocate the array for buffering.

input_device_configuration, output_device_configuration = get_sound_devices(shared_data)
# Opening streams. This gets connections to a sound device and ensures the device is active. Opening a stream with this API locks the shared_data array from being garbage collected.
input_stream  = open(input_device_configuration,  (shared_data, false))
output_stream = open(output_device_configuration, (shared_data, false))

Threads.@spawn start_loop(input_stream,output_stream)
# At any moment you could peek into shared_data and see the actual data.
```

2. Playing Wav files
```julia
using SamplesCore, WavNative, SoundIO
get_audio_sample_rate(audio_data::AbstractDomainArray{T,N}) where {T,N} = (T <: Sample) ? interpret_rate(rate(audio_data,1)) : interpret_rate(rate(audio_data,2))
function play_audio(device::SoundDevice,layout::SoundDeviceChannelLayout,audio_data::AbstractDomainArray{T,N}) where {T,N}
    device_configuration = SoundDeviceConfiguration(device,layout,get_audio_sample_rate(audio_data),T)
    stream = open(device_configuration, (audio_data, false)) # The stream captures the audio data from being Garbage collected.
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
enumerate_devices!(sound_devices)
audio_device::SoundDevice = list_devices(sound_devices).outputs[1]
layout = audio_device.layouts[1]
println("🎶 Playing: $sound_file")
audio_data::DomainArray = audioread(sound_file,false) # DomainArray contains information about sample rate.
#audio_view = view(audio_data,0:10) # range provided in domain axis. Here it provides the first 10 seconds.
play_audio(audio_device,layout,audio_data)
println("Finished!")
```
More demo code can be found at \test

### Acknowledgments

I would like to thank:

Andrew Kelley, the developer of libsoundio, for such a fantastic and robust C library.

The Images.jl developers for providing the architectural guidance and the concept of literate programming that inspired this ecosystem.

The Julia developers for creating such an awesome language that truly allows us to “have our cake and eat it too”—achieving high-level expressiveness without sacrificing low-level performance.
