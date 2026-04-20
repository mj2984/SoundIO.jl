const GLOBAL_CONTEXT = Ref{Union{Nothing, SoundDeviceContext}}(nothing)

function get_context()
    if GLOBAL_CONTEXT[] === nothing || !isopen(GLOBAL_CONTEXT[])
        GLOBAL_CONTEXT[] = SoundDeviceContext()
        connect!(GLOBAL_CONTEXT[])
    end
    return GLOBAL_CONTEXT[]
end

# Now you can simplify the API:
enumerate_devices!(::Sound_Devices) = enumerate_devices!(get_context())
list_devices(::Sound_Devices, access::SoundAccessType=rawsoundaccess) = list_devices(GLOBAL_CONTEXT[], access)
function with_context(f::Function)
    if GLOBAL_CONTEXT[] !== nothing && isopen(GLOBAL_CONTEXT[])
        return f(GLOBAL_CONTEXT[]) # Borrow
    else
        ctx = SoundDeviceContext() # Own
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

struct SoundDeviceError <: Exception
    code::Int32
end

#@inline function check_err(result::Cint)
#    result == 0 && return nothing
#    throw(SoundIOError(result))
#end

#@inline function check_err(result::Cint)
#    result == 0 || throw(SoundIOError(result))
#end

function Base.showerror(io::IO, e::SoundDeviceError)
    sym = get(SoundDeviceErrorMap, e.code, :UnknownError)
    c_msg_ptr = ccall((:soundio_strerror, libsoundio), Ptr{Cchar}, (Cint,), e.code)
    msg = c_msg_ptr != C_NULL ? unsafe_string(c_msg_ptr) : "No message provided."
    print(io, "SoundDeviceError [:$sym]: $msg (Code: $(e.code))")
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
