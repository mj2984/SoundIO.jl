using Libdl

# --- OS-Specific Constants & Memory Mapping ---

const PAGE_SIZE = Int(Sys.iswindows() ? 65536 : 4096)

function allocate_mirrored_buffer(frames::Integer, channels::Integer)
    bytes_per_sample = sizeof(Int32)
    requested_bytes = frames * channels * bytes_per_sample
    # Must be a multiple of page size for mapping hardware to work
    size = ceil(Int, requested_bytes / PAGE_SIZE) * PAGE_SIZE
    
    if Sys.iswindows()
        return _allocate_windows(size)
    else
        return _allocate_posix(size)
    end
end

function _allocate_posix(size::Int)
    # 1. Create anonymous shared memory
    fd = ccall(:shm_open, Cint, (Cstring, Cint, UInt32), "/sio_ring_$(rand(UInt32))", 0x02 | 0x40, 0o600)
    ccall(:ftruncate, Cint, (Cint, Int), fd, size)
    ccall(:shm_unlink, Cint, (Cstring,), "/sio_ring_$(rand(UInt32))")

    # 2. Reserve 2x virtual address space
    addr = ccall(:mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int),
                 C_NULL, 2 * size, 0x00, 0x02 | 0x20, -1, 0)

    # 3. Map physical memory to both halves
    ccall(:mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int),
          addr, size, 0x01 | 0x02, 0x01 | 0x10, fd, 0)
    ccall(:mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int),
          addr + size, size, 0x01 | 0x02, 0x01 | 0x10, fd, 0)
          
    ccall(:close, Cint, (Cint,), fd)
    return addr, size
end

function _allocate_windows(size::Int)
    # Create page-file backed section
    h_section = ccall((:CreateFileMappingW, "kernel32"), Ptr{Cvoid}, 
                      (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, UInt32, UInt32, Ptr{Cvoid}), 
                      -1, C_NULL, 0x04, 0, size, C_NULL)

    # Reserve 2x address space with placeholders
    addr = ccall((:VirtualAlloc2, "kernel32"), Ptr{Cvoid}, 
                 (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, UInt32, UInt32, Ptr{Cvoid}, UInt32),
                 C_NULL, C_NULL, 2 * size, 0x2000 | 0x4000, 0x00, C_NULL, 0)

    # Map twice to the same section
    for offset in (0, size)
        ccall((:MapViewOfFile3, "kernel32"), Ptr{Cvoid}, 
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, UInt64, Csize_t, UInt32, UInt32, Ptr{Cvoid}, UInt32),
              h_section, -1, addr + offset, 0, size, 0x4000, 0x04, C_NULL, 0)
    end

    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), h_section)
    return addr, size
end

# --- The "Magic" Buffer Structs ---

mutable struct CyclicAudioStream
    read_idx::Int64    # Hardware position
    write_idx::Int64   # Julia position
    buffer_frames::Int64
    is_playing::Bool
    _areas_ref::Ref{Ptr{SoundIoChannelArea_C}}
    _frames_ref::Ref{Cint}
end

mutable struct MirroredAudioBuffer
    layout::FrozenAudioLayout
    stream::CyclicAudioStream
    total_bytes::Int

    function MirroredAudioBuffer(frames::Integer, channels::Integer)
        addr, bytes = allocate_mirrored_buffer(frames, channels)
        
        # Recalculate actual frames based on page alignment
        actual_frames = div(bytes, channels * sizeof(Int32))
        
        lay = FrozenAudioLayout(addr, actual_frames, channels)
        st  = CyclicAudioStream(0, 0, actual_frames, true, Ref{Ptr{SoundIoChannelArea_C}}(), Ref{Cint}(0))
        
        obj = new(lay, st, bytes)
        finalizer(obj) do o
            if Sys.iswindows()
                ccall((:UnmapViewOfFile, "kernel32"), Cint, (Ptr{Cvoid},), o.layout.data_ptr)
                ccall((:UnmapViewOfFile, "kernel32"), Cint, (Ptr{Cvoid},), o.layout.data_ptr + o.total_bytes)
            else
                ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), o.layout.data_ptr, 2 * o.total_bytes)
            end
        end
        return obj
    end
end

# --- Extreme Performance Callback (No Wrap Logic) ---

function magic_cyclic_callback(os_ptr::Ptr{SoundIoOutStream_C}, f_min::Cint, f_max::Cint)
    os = unsafe_load(os_ptr)
    buf = unsafe_pointer_to_objref(os.userdata)::MirroredAudioBuffer
    lay, st = buf.layout, buf.stream

    st._frames_ref[] = f_max
    ccall(SIO_BEGIN_WRITE[], Cint, (Ptr{Cvoid}, Ptr{Ptr{SoundIoChannelArea_C}}, Ptr{Cint}), 
          os_ptr, st._areas_ref, st._frames_ref)

    actual_frames = st._frames_ref[]
    dest_ptr = convert(Ptr{Int32}, unsafe_load(st._areas_ref[]).ptr)
    
    # Distance available to read
    available = (st.write_idx - st.read_idx + st.buffer_frames) % st.buffer_frames
    to_copy = min(actual_frames, available)

    if st.is_playing && to_copy > 0
        # NO BRANCH: The mirrored memory handles the wrap-around automatically
        src = lay.data_ptr + (st.read_idx * lay.channels * sizeof(Int32))
        unsafe_copyto!(dest_ptr, src, to_copy * lay.channels)
        st.read_idx = (st.read_idx + to_copy) % st.buffer_frames
    end

    # Silence the rest
    if to_copy < actual_frames
        silence_ptr = dest_ptr + (to_copy * lay.channels * sizeof(Int32))
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), 
              silence_ptr, 0, (actual_frames - to_copy) * lay.channels * sizeof(Int32))
    end

    ccall(SIO_END_WRITE[], Cint, (Ptr{Cvoid},), os_ptr)
    return nothing
end

# --- Julia Producer ---

function push_audio!(buffer::MirroredAudioBuffer, data::Matrix{Int32})
    lay, st = buffer.layout, buffer.stream
    channels, incoming_frames = size(data)
    
    available = (st.read_idx - st.write_idx + st.buffer_frames - 1) % st.buffer_frames
    to_push = min(incoming_frames, available)
    
    to_push <= 0 && return 0

    # NO BRANCH: Single copy into the mirrored region
    dest = lay.data_ptr + (st.write_idx * lay.channels * sizeof(Int32))
    unsafe_copyto!(dest, pointer(data), to_push * lay.channels)

    st.write_idx = (st.write_idx + to_push) % st.buffer_frames
    return to_push
end
