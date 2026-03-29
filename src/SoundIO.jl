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
       
const GLOBAL_CONTEXT = Ref{Union{Nothing, SoundIOContext}}(nothing)

function get_context()
    if GLOBAL_CONTEXT[] === nothing || !isopen(GLOBAL_CONTEXT[])
        GLOBAL_CONTEXT[] = SoundIOContext()
        connect!(GLOBAL_CONTEXT[])
    end
    return GLOBAL_CONTEXT[]
end

# Now you can simplify the API:
enumerate_sound_devices!() = enumerate_devices!(get_context())
list_sound_devices() = list_devices(GLOBAL_CONTEXT[])
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
#=
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
=#

struct SoundIOError <: Exception
    code::Int32
end

#@inline function check_err(result::Cint)
#    result == 0 && return nothing
#    throw(SoundIOError(result))
#end

#@inline function check_err(result::Cint)
#    result == 0 || throw(SoundIOError(result))
#end

function Base.showerror(io::IO, e::SoundIOError)
    sym = get(SoundIoErrorMap, e.code, :UnknownError)
    c_msg_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), e.code)
    msg = c_msg_ptr != C_NULL ? unsafe_string(c_msg_ptr) : "No message provided."
    print(io, "SoundIOError [:$sym]: $msg (Code: $(e.code))")
end

#function open_sound_stream_error_check(result::Cint)
#    result == 0 && return nothing
#    c_str = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), result)
#    throw(SoundIOError(result, unsafe_string(c_str)))
#end

#=
Mapping errors to negative values is a classic C-style "Return Code" pattern (like Linux syscalls). Since you are already mapping to Symbols, I suggest going one step further: Return the Symbol for errors and an Integer for success.
If you prefer the integer-based logic for performance:
> 0: Frames processed.
0: Success/EOF.
< 0: -(ErrorEnumIndex).
=#
end
