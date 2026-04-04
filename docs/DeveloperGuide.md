# 🛠️ Developer Guide: Custom Transport Layers

SoundIO.jl is built to be extended. While the **Frozen Audio Buffer** is the built-in "Flow" model, the infrastructure allows you to define your own synchronization logic—like lock-free ring buffers or reactive DSP pipes—by subtyping `SoundIOSynchronizer`.

---

## 🏗️ The Blueprint

To create a custom transport layer, you need:
1.  **A Synchronizer Struct**: A type that subtypes `SoundIOSynchronizer`.
2.  **A Callback Function**: A performance-critical function for the hardware thread.

### 🔬 Case Study: How `FrozenAudioBuffer` is Implemented

The `FrozenAudioBuffer` is our reference implementation. It uses **Type-Specialization** and **Multiple Dispatch** to eliminate branches, ensuring the CPU spends its time moving data rather than checking logic.

#### 1. Library Transport Functions
To simplify hardware interaction, the library provides two core functions that handle the complex `Ref` management and C-interface requirements of **libsoundio**.

- **`negotiate_callback_buffer_space(stream_ptr, requested_frames, T)`**: 
  This is your entry point for every callback. It communicates with the OS sound driver to determine how much memory is actually available.
  - **Inputs**: The hardware stream pointer, requested frame count, and sample type `T`.
  - **Returns**: A tuple containing the typed pointer `Ptr{T}` to the hardware buffer and the `actual_frames` (Int) granted by the driver.
  
- **`commit_callback_buffer!(stream_ptr)`**:
  Once your data transfer is complete, you **must** call this function. It notifies the OS that the buffer is ready for playback or has been processed.

#### 2. Low-Level Utility Helpers
We define small, `@inline` functions to handle pointer arithmetic and symmetric data transfer. These allow the main callback to remain readable while ensuring zero overhead.

> **⚠️ Important Note on Pointer Arithmetic:** In Julia, `ptr + 1` moves by **1 byte**, not 1 element. We must manually multiply by `sizeof(T)`. However, `unsafe_copyto!` and `stream_space_reset!` (via `ccall`) work with **element counts** or **byte counts** respectively—precision here is key.

```julia
# --- Pointer Math: Manual Byte-Scaling Required ---

# Resolves to the base memory address of the current buffer segment (atom)
@inline get_source_ptr_base(buffer::FrozenAudioBuffer{T,isatomic}) where {T} = 
    isatomic ? buffer.layout.data_ptr + (buffer.stream.current_offset_base * sizeof(T)) : 
               buffer.layout.data_ptr

# Resolves to the exact address within the atom, accounting for the current frame offset
@inline get_source_ptr(buffer::FrozenAudioBuffer{T,isatomic}) where {T} = 
    isatomic ? buffer.layout.data_ptr + ((buffer.stream.current_offset_base + buffer.stream.atomic_frame_offset) * sizeof(T)) : 
               buffer.layout.data_ptr + (buffer.stream.atomic_frame_offset * sizeof(T))

# --- Data Transfer: Automatic Element-Scaling ---

# Calculates remaining frames in the current atom to prevent buffer overruns
@inline get_frames_to_copy(buffer::FrozenAudioBuffer, actual_frames::Int) = 
    min(actual_frames, buffer.layout.atom_frames - buffer.stream.atomic_frame_offset)

# Symmetric Transfer: Direction resolved at compile-time via Multiple Dispatch
# Note: unsafe_copyto! uses element counts, NOT byte counts.
@inline stream_direction_transfer!(dest::Ptr{T}, src::Ptr{T}, frames::Int, ::Type{SoundIoInputStream_C}) where {T} = 
    unsafe_copyto!(src, dest, frames)

@inline stream_direction_transfer!(dest::Ptr{T}, src::Ptr{T}, frames::Int, ::Type{SoundIoOutputStream_C}) where {T} = 
    unsafe_copyto!(dest, src, frames)

# Zeroing Memory: Direct C call for maximum speed (requires manual byte count)
@inline function stream_space_reset!(ptr::Ptr{T}, frames::Integer) where {T}
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ptr, 0, frames * sizeof(T))
end
```
#### 3. The Boundary Handler (Logic & Sync)
This function manages the "rollover" when we reach the end of a buffer slice (an "atom"). It updates the atomic state and notifies the Julia event loop that a segment is complete.
```julia
function frozen_audio_callback_boundary_handler!(::Type{StreamBaseType}, 
    buffer::FrozenAudioBuffer{T,isatomic,isclearing}, 
    destination_ptr::Ptr{T}, frames_copied::Int, 
    actual_frames::Int) where {StreamBaseType,T,isatomic,isclearing}
    
    layout, stream = buffer.layout, buffer.stream
    exchange::FrozenAudioExchange = @atomic stream.exchange
    
    pending_frames = actual_frames - frames_copied
    # Manual byte-scaling: destination_ptr + (offset * bytes_per_element)
    starting_ptr = destination_ptr + (frames_copied * sizeof(T))
    
    elapsed_atoms::Int = isatomic ? exchange.elapsed_atoms + 1 : 0
    stream.atomic_frame_offset = pending_frames
    return_status::Int8 = exchange.status

    if return_status == CallbackJuliaDone
        if isatomic
            # Wrap offset back to 0 if we hit the end of the total buffer
            next_offset_base = (stream.current_offset_base + layout.atom_frames) % (layout.total_atoms * layout.atom_frames)
            stream.current_offset_base = next_offset_base
        end
        
        # Transfer the remaining frames from the START of the next atom
        next_atom_ptr = get_source_ptr_base(buffer)
        stream_direction_transfer!(starting_ptr, next_atom_ptr, pending_frames, StreamBaseType)
        
        if isclearing
            stream_space_reset!(next_atom_ptr, pending_frames)
        end
    else
        # If the stream was stopped, fill the hardware buffer with silence
        return_status = CallbackStopped
        stream_space_reset!(starting_ptr, pending_frames)
    end

    # 🔄 ATOMIC UPDATE: Sync state and notify Julia (via libuv)
    @atomic stream.exchange = FrozenAudioExchange(pending_frames, elapsed_atoms, return_status)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), stream.notify_handle.handle)
end
```
#### 4. The Main Callback
The entry point orchestrating negotiation, transfer, and boundary checks.
```julia
function frozen_audio_callback(outstream_ptr::Ptr{StreamBaseType}, 
                               f_min::Cint, f_max::Cint, 
                               buffer::FrozenAudioBuffer{T,isatomic,isclearing}) where {StreamBaseType,T,isatomic,isclearing}
    
    # 1. Hardware Negotiation
    destination_ptr, actual_frames::Int = negotiate_callback_buffer_space(outstream_ptr, f_max, T)
    
    # 2. Pointer Setup
    source_ptr = get_source_ptr(buffer)
    frames_to_copy::Int = get_frames_to_copy(buffer, actual_frames)
    
    # 3. Main Transfer
    if frames_to_copy > 0
        stream_direction_transfer!(destination_ptr, source_ptr, frames_to_copy, StreamBaseType)
        if isclearing
            stream_space_reset!(source_ptr, frames_to_copy)
        end
        buffer.stream.atomic_frame_offset += frames_to_copy
    end

    # 4. Handle Rollover (Boundary Logic)
    if frames_to_copy < actual_frames
        frozen_audio_callback_boundary_handler!(StreamBaseType, buffer, destination_ptr, frames_to_copy, actual_frames)
    end

    # 5. Commit to OS
    commit_callback_buffer!(outstream_ptr)
    return nothing
end
```
## 🚦 Managing Stream State & Notifications

When building a custom transport, you must ensure that your synchronizer can receive state updates from the engine (e.g., when a stream starts, stops, or errors).

### Implementing the Status Handshake
The engine calls `update_callback_status_message` to synchronize the Julia-side intent with the hardware thread's state. You must define this method for your custom synchronizer to ensure `start!(stream)` works correctly.

```julia
# Example: How FrozenAudioBuffer handles status updates atomically
@inline function update_callback_status_message(sync::MyCustomBuffer, status::Int8)
    # We use @atomic to ensure the audio thread sees the state change immediately
    exchange = @atomic sync.exchange
    @atomic sync.exchange = MyExchange(exchange.progress, status)
    return nothing
end
```
## 🚀 Attaching Your Custom Layer

To launch a custom layer, use the high-level `open_sound_stream` method. It handles the `@cfunction` generation and **GC Anchoring** automatically.

```julia
# 1. Instantiate your custom synchronizer
my_sync = MyCustomBuffer(zeros(Float32, 1024), CallbackJuliaDone)

# 2. Open the stream
# 'my_sync.data' is preserved to ensure the GC doesn't move it during playback
stream = open_sound_stream(
    device, 
    my_sync, 
    frozen_audio_callback, 
    my_sync.data, 
    44100, 
    :Float32Little
)

# 3. Start the hardware clock
start!(stream)
```
## 🧠 Automation with Multiple Dispatch

Because `SoundIO.jl` leverages Julia's dispatch system, you can create convenient `Base.open` wrappers. This allows the library to automatically infer parameters from your data structures:

```julia
function Base.open(device::SoundIODevice, data::AbstractArray{T, N}, sample_rate::Integer) where {T, N}
    # Validate that memory is contiguous for unsafe pointers
    if !is_pointer_safe(data)
        error("Non-contiguous arrays (slices) are not supported.")
    end
    
    # Calculate dimensions for the synchronizer
    channels = size(data, 1)
    frames = size(data, 2)
    
    # 'data' is passed twice: once as the source and once to the 'preserve' 
    # argument to ensure GC safety while the hardware thread is active.
    return open_sound_stream(device, data, frozen_audio_callback, data, sample_rate, :Float32Little)
end
```
## 🛡️ Developer Best Practices for the "Hot Path"

To ensure your custom transport layer maintains native-level performance and avoids audio glitches (stutters), follow these core recommendations when writing callbacks:

*   **Zero-Allocation Logic:** The audio thread must never trigger Julia's Garbage Collector. Avoid creating arrays, strings, dictionaries, or any other heap-allocated objects.
*   **Static Type Stability:** Always use `where {T, ...}` in your callback signature. This ensures the compiler can statically resolve all types, eliminating dynamic dispatch and generating optimized, branchless machine code.
*   **Memory Anchoring (GC Safety):** Because hardware threads access memory outside of Julia's awareness, always use the `preserve` argument in `open_sound_stream`. This anchors your data buffers and prevents the GC from moving or reclaiming them while the stream is active.
*   **Event Loop Signaling:** Use `ccall(:uv_async_send, ...)` to communicate with the rest of your application. This safely signals the Julia event loop from the hardware thread, allowing your main tasks to respond to stream events without blocking the audio clock.
