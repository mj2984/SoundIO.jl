using SamplesCore, SoundIO, WavNative
#using PtrArrays
# Frozen Audio Buffer Example.
function play_audio(device_configuration::SoundIODeviceConfiguration, audio_data::AbstractDomainArray)
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
# AudioCallbackSynchronizer Example.
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T, Channels}, audio_data::AbstractArray{Sample{Channels,T}}) where {T, Channels}
    total_frames::Int = size(audio_data, 1)
    current_frame::Int = 0
    GC.@preserve audio_data begin
        while current_frame < total_frames
            res::Union{Symbol,Array{Sample{Channels,T},1}} = acquire_sound_buffer(sync)
            if res isa Symbol
                break
            end
            curr_buf::Array{Sample{Channels,T}} = res
            buf_frames::Int = size(curr_buf, 1)
            rem_frames::Int = total_frames - current_frame
            to_copy::Int = min(buf_frames, rem_frames)
            @views copyto!(curr_buf[1:to_copy], audio_data[current_frame+1:current_frame+to_copy])
            if to_copy < buf_frames
                @views fill!(curr_buf[to_copy+1:end], zero(Sample{Channels, T}))
            end
            #=
            dst_ptr, buf_frames = acquire_sound_buffer_ptr(sync)
            dst_ptr == C_NULL && break
            to_copy = min(buf_frames, total_frames - current_frame)
            src_ptr = pointer(audio_data, (current_frame * Channels) + 1)
            unsafe_copyto!(dst_ptr, src_ptr, to_copy * Channels)
            if to_copy < buf_frames
                silence_ptr = dst_ptr + (to_copy * Channels * sizeof(T))
                ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), silence_ptr, 0, (buf_frames - to_copy) * Channels * sizeof(T))
            end
            =#
            current_frame += to_copy
            if(current_frame < total_frames)
                release_sound_buffer(sync)
            end
        end
    end
    halt_sound_buffer(sync)
end
# Uses the audio_streamer_ram_playback to manage streaming.
function play_audio_threaded(device::SoundIODevice, audio_data::AbstractDomainArray{T,N}) where {T<:Sample,N}
    stream = SoundIO.open_sound_stream(device, audio_data.rate[1], T, nothing)
    sync = stream.sync[]
    worker_task = Threads.@spawn :interactive audio_streamer_ram_playback(sync, audio_data.data)
    start!(stream)
    wait(worker_task)
    destroy_sound_stream_unsafe(stream)
    println("Playback finished.")
end
#1. The Watcher (Runs in the background)
#=
event_task = @async begin
    while isopen(ctx)
        wait_unsafe!(ctx) # Blocks here at 0% CPU until a hardware event occurs
        put!(event_channel, :hardware_changed) # Notify the rest of the app
    end
end#
# 2. The Playback Loop (Runs in the foreground)
while !buffer.stream.is_finished
    # We don't 'wait' here because we don't want to stop the music 
    # just to listen for a USB plug-in.
    flush_events!(ctx) # Quickly check for errors/unplugs
    sleep(0.01)        # Keep REPL alive for Ctrl+C
end
=#

#=
macro audio_callback(func_expr)
    # 1. Parse the function signature to find the buffer type
    # We expect: function name(ptr, min, max, buffer::SpecificType)
    if !Meta.isexpr(func_expr, :function)
        error("Macro must be applied to a function definition.")
    end
    
    sig = func_expr.args[1]
    # Find the last argument: buffer::SpecificType
    last_arg = sig.args[end]
    
    if !Meta.isexpr(last_arg, :(::))
        error("The last argument of the callback must have a type annotation (e.g., buffer::MyBufferType).")
    end
    
    # Extract the Type (e.g., FrozenAudioBuffer{...})
    buffer_type = last_arg.args[2]
    func_name = sig.args[1]

    return quote
        # Define the user function normally
        $(esc(func_expr))
        
        # Generate the @cfunction specialized for this specific type
        # The closure handles the pointer-to-object retrieval
        @cfunction(Cvoid, (Ptr{SoundIoOutStream_C}, Cint, Cint)) do out_ptr, f_min, f_max
            buffer = get_audio_buffer(out_ptr, $buffer_type)
            $(esc(func_name))(out_ptr, f_min, f_max, buffer)
            return nothing
        end
    end
end

# The macro 'sees' FrozenAudioBuffer and bakes it into the @cfunction
ptr = @audio_callback function my_dsp_logic(
    out_ptr, 
    f_min, 
    f_max, 
    buffer::FrozenAudioBuffer{Float32, 2, true, true, true}
)
    # Pure DSP logic here
    # 'buffer' is already the resolved Julia object
end
=#
