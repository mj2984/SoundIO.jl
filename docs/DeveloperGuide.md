# SoundIO.jl Developer Guide

This guide explains the internal mechanics of SoundIO.jl: how callbacks are generated, how streams work, and how synchronization is handled.

---

## 1. Streams

Streams wrap libsoundio’s input/output stream objects.

### Output Streams
`SoundIOOutStream` contains:
- the raw C pointer  
- format, sample rate, channel layout  
- the Julia callback  
- buffer state  
- GC preservation handles  

### Input Streams
`SoundIOInStream` mirrors the same structure for input.

Streams are opened using:
~~~julia
open(device)
~~~

and closed with:
~~~julia
close(stream)
~~~

---

## 2. Callback Generation

Callbacks are created using type specialization:

~~~julia
cb = make_sound_output_callback(stream, userfunc)
stream.write_callback = cb
~~~

### How it works
- The function specializes on the concrete stream type.  
- A closure is created that captures:
  - the stream  
  - the user’s Julia function  
  - any additional state  
- The closure is converted into a C-callable function pointer.  
- libsoundio invokes this pointer from the audio thread.  

### Why this is fast
- No dynamic dispatch inside the callback  
- No symbol lookups  
- No heap allocations  
- The compiler can inline aggressively  

### Why this is safe
- The stream wrapper enforces correct usage  
- Buffers are wrapped in `GC.@preserve`  
- Errors are surfaced as Julia symbols  
- Users can still access raw pointers if needed  

---

## 3. Synchronization

libsoundio uses a high-priority audio thread.  
SoundIO.jl bridges this with Julia tasks using two mechanisms:

### Fast Wait
~~~julia
wait(context)
wait(device)
~~~

Used for:
- real-time synthesis  
- pinned-thread workers  
- low-latency loops  

### Event-Driven Wait
Callbacks trigger Julia tasks at lower frequency.

Useful for:
- GUIs  
- monitoring  
- asynchronous pipelines  

---

## 4. Threaded Workers

A worker task can be pinned to a specific Julia thread:

~~~julia
task = @task audio_streamer(sync, data)
ccall(:jl_set_task_tid, Cvoid, (Any, Int16), task, 5)
task.sticky = true
schedule(task)
~~~

The audio callback signals the worker via `AudioCallbackSynchronizer`.

---

## 5. Extending SoundIO.jl

You can extend the system by defining new methods on existing types:
- custom stream wrappers  
- ring buffers  
- DSP pipelines  
- alternate callback generators  
- async processors  

The architecture is intentionally minimal to support this.

---

MIT License.
