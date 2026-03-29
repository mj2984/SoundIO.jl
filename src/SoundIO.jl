# SoundIO.jl - Julia bindings for libsoundio
# Copyright (c) 2026 mj2984. Licensed under the MIT License.
# libsoundio is Copyright (c) 2015 Andrew Kelley.
module SoundIO
include("SamplesCore.jl")
#using ..SamplesCore
using Libdl, libsoundio_jll, FixedPointNumbers
include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")
include("SoundIOBaseCallbacks.jl")
export SoundIOContext, SoundIODevice, SoundIOOutStream, FrozenAudioStream, FrozenAudioExchange,
       SoundIOSynchronizer, AudioCallbackSynchronizer,
       is_connected_unsafe, is_connected,open_unsafe!, open!, connect_unsafe!, connect!,
       disconnect_unsafe!, disconnect!, flush_events_unsafe!, flush_events!, wait_unsafe,
       enumerate_devices_unsafe!, enumerate_devices!, supported_formats,
       start!, CallbackStopped, CallbackJuliaDone, CallbackStatusReady,
       acquire_sound_buffer_ptr, acquire_sound_buffer, release_sound_buffer, halt_sound_buffer,
       destroy_sound_stream_unsafe, destroy_sound_stream!, AudioCallbackMessage
end
#=
const GLOBAL_CONTEXT = Ref{Union{Nothing, SoundIOContext}}(nothing)

"""
    get_context()
Return the global SoundIO context, initializing and connecting it if necessary.
"""
function get_context()
    if GLOBAL_CONTEXT[] === nothing || !isopen(GLOBAL_CONTEXT[])
        GLOBAL_CONTEXT[] = SoundIOContext()
        connect!(GLOBAL_CONTEXT[])
    end
    return GLOBAL_CONTEXT[]
end

"""
    with_context(f)
Run `f(ctx)`. If a global context exists, it borrows it. 
Otherwise, it creates, connects, and ensures the context is closed afterward.
"""
function with_context(f::Function)
    if GLOBAL_CONTEXT[] !== nothing && isopen(GLOBAL_CONTEXT[])
        return f(GLOBAL_CONTEXT[])
    else
        ctx = SoundIOContext()
        try
            connect!(ctx)
            GLOBAL_CONTEXT[] = ctx
            return f(ctx)
        finally
            close(ctx)
            GLOBAL_CONTEXT[] = nothing
        end
    end
end

=#
#=
# Inside the module
const DEFAULT_CONTEXT = Ref{Union{Nothing, SoundIOContext}}(nothing)

function get_context()
    if DEFAULT_CONTEXT[] === nothing || !isopen(DEFAULT_CONTEXT[])
        DEFAULT_CONTEXT[] = SoundIOContext()
        connect!(DEFAULT_CONTEXT[])
    end
    return DEFAULT_CONTEXT[]
end

# Now you can simplify the API:
enumerate_devices!() = enumerate_devices!(get_context())

=#
#=
struct SoundIOError <: Exception
    code::Int32
    msg::String
end

# Overload show to make it look professional
function Base.showerror(io::IO, e::SoundIOError)
    sym = get(SoundIoErrorMap, e.code, :UnknownError)
    print(io, "SoundIOError [:$sym]: $(e.msg) (Code: $(e.code))")
end

# Usage in your check function:
function open_sound_stream_error_check(result::Cint)
    result == 0 && return nothing
    c_str = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), result)
    throw(SoundIOError(result, unsafe_string(c_str)))
end
=#
#=
Mapping errors to negative values is a classic C-style "Return Code" pattern (like Linux syscalls). Since you are already mapping to Symbols, I suggest going one step further: Return the Symbol for errors and an Integer for success.
If you prefer the integer-based logic for performance:
> 0: Frames processed.
0: Success/EOF.
< 0: -(ErrorEnumIndex).
=#


#=
# --- Professional Error Handling ---
struct SoundIOError <: Exception
    code::Int32
end

function Base.showerror(io::IO, e::SoundIOError)
    sym = get(SoundIoErrorMap, e.code, :UnknownError)
    c_msg_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), e.code)
    msg = c_msg_ptr != C_NULL ? unsafe_string(c_msg_ptr) : "No message provided."
    print(io, "SoundIOError [:$sym]: $msg (Code: $(e.code))")
end

@inline function check_err(result::Cint)
    result == 0 && return nothing
    throw(SoundIOError(result))
end

# --- Global Context & Ownership ---
const GLOBAL_CONTEXT = Ref{Union{Nothing, SoundIOContext}}(nothing)

function get_context()
    if GLOBAL_CONTEXT[] === nothing || !isopen(GLOBAL_CONTEXT[])
        GLOBAL_CONTEXT[] = SoundIOContext()
        connect!(GLOBAL_CONTEXT[])
    end
    return GLOBAL_CONTEXT[]
end

function with_context(f::Function)
    if GLOBAL_CONTEXT[] !== nothing && isopen(GLOBAL_CONTEXT[])
        return f(GLOBAL_CONTEXT[]) # Borrow
    else
        ctx = SoundIOContext() # Own
        try
            connect!(ctx)
            GLOBAL_CONTEXT[] = ctx
            return f(ctx)
        finally
            close(ctx)
            GLOBAL_CONTEXT[] = nothing
        end
    end
end
=#
#=
function connect_unsafe!(ctx::SoundIOContext)
    check_err(ccall((:soundio_connect, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[]))
end

function open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutStream_C})
    check_err(ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr))
end

function start!(stream::SoundIOOutStream)
    update_callback_status_message(stream.sync[], CallbackJuliaDone)
    check_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr))
end
=#

#=
# --- Professional Error Handling ---

"""
    SoundIOError(code::Int32)
Custom exception mapping libsoundio error codes to Julia Symbols and 
descriptive C-backend messages.
"""
struct SoundIOError <: Exception
    code::Int32
end

function Base.showerror(io::IO, e::SoundIOError)
    sym = get(SoundIoErrorMap, e.code, :UnknownError)
    # Fetch the official technical message from libsoundio
    c_msg_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), e.code)
    msg = c_msg_ptr != C_NULL ? unsafe_string(c_msg_ptr) : "No message provided."
    print(io, "SoundIOError [:$sym]: $msg")
end

@inline function check_err(result::Cint)
    result == 0 || throw(SoundIOError(result))
end

# --- Smart Context Ownership ---

const GLOBAL_CONTEXT = Ref{Union{Nothing, SoundIOContext}}(nothing)

"""
    get_context()
Returns the global SoundIO context. Initializes and connects it automatically if needed.
"""
function get_context()
    if isnothing(GLOBAL_CONTEXT[]) || !isopen(GLOBAL_CONTEXT[])
        GLOBAL_CONTEXT[] = SoundIOContext()
        connect!(GLOBAL_CONTEXT[])
    end
    return GLOBAL_CONTEXT[]
end

"""
    with_context(f::Function)
Executes `f(ctx)`. Borrows the global context if active, or creates, connects, 
and safely closes a new one specifically for the duration of the block.
"""
function with_context(f::Function)
    ctx_ref = GLOBAL_CONTEXT[]
    if !isnothing(ctx_ref) && isopen(ctx_ref)
        return f(ctx_ref) # Borrow existing
    else
        ctx = SoundIOContext() # Create new ownership
        try
            connect!(ctx)
            GLOBAL_CONTEXT[] = ctx
            return f(ctx)
        finally
            close(ctx)
            GLOBAL_CONTEXT[] = nothing
        end
    end
end

# --- Updated Lifecycle & Connection Methods ---

function connect_unsafe!(ctx::SoundIOContext)
    check_err(ccall((:soundio_connect, libsoundio), Cint, (Ptr{Cvoid},), ctx.ptr[]))
end

function open_sound_stream_unsafe!(ptr::Ptr{SoundIoOutStream_C})
    check_err(ccall((:soundio_outstream_open, libsoundio), Cint, (Ptr{Cvoid},), ptr))
end

function start!(stream::SoundIOOutStream)
    update_callback_status_message(stream.sync[], CallbackJuliaDone)
    check_err(ccall((:soundio_outstream_start, libsoundio), Cint, (Ptr{Cvoid},), stream.ptr))
end
=#
