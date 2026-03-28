# SoundIO.jl
**Transparent, high-performance audio transport.**

**SoundIO.jl** is a high-quality streaming engine built on the robust `libsoundio` backend. It provides a Julia-native API for direct, low-latency access to your audio hardware, designed for developers who need full visibility and precise control over their signal path. By merging the surgical control of a systems-level interface with Julia’s rapid development workflow, you can achieve native-level efficiency within a safe, expressive, and interactive environment.

---

## 🎯 Philosophy: Zero-Cost Abstractions
SoundIO.jl lets you **have your cake and eat it too**: achieve maximum performance through code that is self-documenting.

*   **Compile-Time Specialization:** We leverage Julia’s type system to generate optimized callback functions on the fly. The engine generates the optimal instructions by specializing on your stream's parameters—allowing your code to read like documentation while executing with the efficiency of hand-tuned machine procedures.
*   **Interactive Exploration:** Designed for the REPL, the library acts like a text-based device manager. Custom pretty-printing and emojis provide a "GUI-like" overview of hardware capabilities—contexts, devices, and formats—as easily as inspecting a local variable.
*   **Safe by Construction:** A stable, high-level buffer abstraction is provided for general use, but even custom implementations benefit from Julia-native abstractions for callbacks and optional managed GC-preservation. This design allows a Julia developer to leverage peak hardware performance without needing low-level systems programming expertise.

---

## 🚀 Why SoundIO.jl?

SoundIO.jl offers transparent audio hardware access, bypassing OS mixing to support raw data formats from PCM to high-precision telemetry. Engineered for performance, it features minimal latency, zero allocations in the hot path, and safe abstractions for low-level resource management.

*   **Transparent & Raw:** Drive your hardware exactly as intended. We ensure no hidden OS "magic" or resampling interferes with your signal path.¹
*   **Performance First:** Internal buffers and synchronizers are designed for minimal latency and zero allocations in the hot path.
*   **Intuitive & Julian:** A professional systems-level API providing safety as a zero-cost abstraction, featuring rich REPL pretty-printing and Symbol-based error handling.
*   **Extensible by Design:** Whether using the highly customizable built-in **Frozen Audio Buffer** or defining a custom transport layer using **`<:SoundIOSynchronizer`**, the infrastructure is built to be extended without sacrificing performance. Our type-specialized pipeline allows you to transform normal Julia code into high-performance callbacks for tasks like signal processing and real-time data packing.

> <sup>1</sup> *Transparency is guaranteed for 'Raw' devices; behavior on non-raw devices depends on the OS backend.*

---

## 🧱 Core Synchronization Mechanisms
SoundIO.jl provides highly customizable mechanisms for both ends of the streaming spectrum, while allowing users to define their own custom solutions if required.

1.  **Frozen Audio Buffer (The "Pull" Model)**: A unique mechanism that turns a standard Julia array into a managed ring buffer with customizable synchronization atoms. The engine streams the data autonomously, only notifying the user at atom boundaries or if an error occurs—allowing you to focus on signal generation in peace, trusting the engine to handle the delivery.
    *   **Snapshots:** Provides atomic progress updates to the Julia task, enabling you to adapt to hardware consumption rates with minimal "peeking" at the callback state.
    *   **Automatic Safety:** Buffers are kept alive (GC-safe) automatically for the lifetime of the stream.
    *   **Customizable Boundaries:** Synchronization atoms are intelligently inferred from your array dimensions to match your application's logic.

2.  **Audio Callback Synchronizer (The "Push" Model)**: Engineered for the lowest possible latency, this model acts as a bridge that notifies a Julia task for every single hardware callback. This is ideal for live synthesis, reactive DSP, or any scenario where you must respond to the hardware in real-time.

3.  **Custom Synchronizers**: The architecture is designed for infinite extensibility. By inheriting from `SoundIOSynchronizer` and defining a custom callback method, you can build specialized transport layers that benefit from the library's optimized, type-specialized compilation pipeline.

The library offers versatile synchronization methods for both system-level event handling and its built-in streaming mechanisms. System-level events like `wait(device)` or `wait(context)` utilize a **native blocking wait** for zero-CPU idling during system changes. The provided synchronizers for audio streams reflect specialized performance philosophies: the **Frozen Audio Buffer** uses **event-driven notifications** for efficient task sleeping, while the **Audio Callback Synchronizer** employs **deterministic spin-waiting** to bypass scheduler overhead—both of which serve as references for users implementing custom solutions.

---

### 🧩 Extensible Stream Framework

SoundIO.jl stays close to a minimal, high-performance philosophy, serving as a robust foundation for building high-level abstractions. By leveraging multiple dispatch and a type-specialized pipeline, the architecture makes it trivial to extend the engine for:

*   **Custom Infrastructure:** Lock-free ring buffers, audio graphs, and complex DSP pipelines.
*   **Reactive Processors:** Asynchronous, task-based processors and custom callback generators.

Beyond audio, SoundIO.jl acts as a high-performance synchronous data transport layer. Using **Exclusive Mode** provides a transparent pipe that bypasses OS mixers—making it an ideal transport for:

*   **Industrial & Medical:** Biomedical signals (ECG/EEG) and industrial sensor telemetry.
*   **High-Precision Data:** Any streaming application requiring deterministic, low-latency delivery.

---

## 📦 Quick Start
SoundIO.jl manages backend connections automatically. Use `with_context` for a clean ownership model:

```julia
using SoundIO

# 1. Prepare Stereo Data
fs = 44100
audio_data = rand(Int16, 2, fs) 

# 2. Play on Default Raw Device
with_context() do ctx
    enumerate_devices!(ctx)
    # Filter for 'Raw' devices for lowest latency
    device = first(filter(d -> !d.is_input && d.is_raw, ctx.devices))
    
    stream = open(device, (audio_data, false), fs, :Int16Little)
    start!(stream)
    wait(stream)
end
