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
```julia
using SoundIO

fs = 44100
t = 0:1/fs:1
sine = Int32.(round.(sin.(2π * 440 .* t) .* (2^31 - 1)))
audio = vcat(sine', sine')

SoundIOContext() do ctx
    enumerate_devices!(ctx)
    dev = first(filter(d -> !d.is_input && d.is_raw, ctx.devices))
    play_audio(audio, fs, ctx, dev, :Int32Little)
end
