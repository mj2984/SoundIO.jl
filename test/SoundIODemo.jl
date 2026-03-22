include(raw"../src/SoundIO.jl")
include(raw"AudioCore.jl")
include(raw"WavNative.jl")
using .SoundIO
using .WavNative
using .AudioCore
#using PtrArrays
# Frozen Audio Buffer Example.
function play_audio(audio_data::AbstractArray{T}, sample_rate::Integer, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32}, T<:Number}
    stream = open(device, (audio_data, false), sample_rate, format) # The stream captures the audio data from being Garbage collected.
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
function audio_streamer_ram_playback(sync::AudioCallbackSynchronizer{T, Channels}, audio_data::AbstractArray{T}) where {T, Channels}
    total_frames::Int = size(audio_data, 2)
    current_frame::Int = 0
    GC.@preserve audio_data begin
        while current_frame < total_frames
            res::Union{Symbol,Matrix{T}} = acquire_sound_buffer(sync)
            if res isa Symbol
                break
            end
            curr_buf::Matrix{T} = res
            buf_frames::Int = size(curr_buf, 2)
            rem_frames::Int = total_frames - current_frame
            to_copy::Int = min(buf_frames, rem_frames)
            @views copyto!(curr_buf[:, 1:to_copy], audio_data[:, current_frame+1:current_frame+to_copy])
            if to_copy < buf_frames
                @views fill!(curr_buf[:, to_copy+1:end], zero(T))
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
function play_audio_threaded(audio_data::AbstractArray{T}, sample_rate::Integer, device::SoundIODevice, format::fmtType) where {fmtType <: Union{Symbol,Int32},T}
    stream = SoundIO.open_sound_stream(device, (T, size(audio_data, 1)), nothing, sample_rate, format)
    sync = stream.sync[]
    worker_task = Threads.@spawn :interactive audio_streamer_ram_playback(sync, audio_data)
    start!(stream)
    wait(worker_task)
    destroy_sound_stream_unsafe(stream)
    println("Playback finished.")
end
function get_destination_format(T::DataType)
    if T == Int32
        return :Int32Little
    elseif T == Int16
        return :Int16Little
    end
end
function play_music(sound_file::String,audio_device::SoundIODevice)
    audio_data,sample_rate = audioread(sound_file,native_output = false)
    audio_data_channelview = channelview(audio_data)
    play_audio(audio_data_channelview,Int(sample_rate),audio_device,get_destination_format(eltype(audio_data_channelview)))
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
