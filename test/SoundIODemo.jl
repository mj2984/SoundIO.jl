include(raw"../src/SoundIO.jl")
using .SoundIO
#using .WavNative
#using .SoundCore
#using PtrArrays
# Frozen Audio Buffer Example.
function play_audio(audio_data::AbstractArray{T}, sample_rate::Integer, device::SoundIODevice) where {T<:Union{Number,Sample}}
    stream = open(device, (audio_data, false), sample_rate) # The stream captures the audio data from being Garbage collected.
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
function play_audio_threaded(audio_data::AbstractArray{T}, sample_rate::Integer, device::SoundIODevice) where {T<:Sample}
    stream = SoundIO.open_sound_stream(device, T, nothing, sample_rate)
    sync = stream.sync[]
    worker_task = Threads.@spawn :interactive audio_streamer_ram_playback(sync, audio_data)
    start!(stream)
    wait(worker_task)
    destroy_sound_stream_unsafe(stream)
    println("Playback finished.")
end
function play_music(sound_file::String,audio_device::SoundIODevice)
    audio_data,sample_rate = audioread(sound_file,false)
    #play_audio(audio_data,Int(sample_rate),audio_device)
    play_audio_threaded(audio_data,Int(sample_rate),audio_device)
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
mutable struct WavpackBitReader
    ptr::Ptr{UInt8}
    bit_buf::UInt64
    bits_in_buf::Int
    offset::Int
    limit::Int
end

@inline function fill_bitbuf!(br::WavpackBitReader)
    # Pull 32 bits at a time into our 64-bit cache
    if br.offset + 4 <= br.limit
        word = unsafe_load(reinterpret(Ptr{UInt32}, br.ptr + br.offset))
        br.bit_buf |= (UInt64(word) << br.bits_in_buf)
        br.bits_in_buf += 32
        br.offset += 4
    end
end

@inline function get_bits(br::WavpackBitReader, n::Int)
    if br.bits_in_buf < n; fill_bitbuf!(br); end
    res = br.bit_buf & ((UInt64(1) << n) - 1)
    br.bit_buf >>= n
    br.bits_in_buf -= n
    return res
end


# Simplified Rice decoding for WavPack
@inline function decode_rice_sample(br::WavpackBitReader, k::Int)
    # 1. Get unary prefix
    count = 0
    while get_bits(br, 1) == 0
        count += 1
    end
    # 2. Get binary remainder
    body = get_bits(br, k)
    val = (count << k) | body
    # 3. Handle sign (WavPack uses bit 0 for sign)
    return (val & 1) != 0 ? -(val >> 1) : (val >> 1)
end

function reconstruct_hybrid!(residuals::Vector{Int32}, br_wv::WavpackBitReader, br_wvc::WavpackBitReader)
    # k is the adaptive Rice parameter from the block metadata
    k = 4 # Example initial value
    @inbounds for i in 1:length(residuals)
        lossy = decode_rice_sample(br_wv, k)
        corr  = decode_rice_sample(br_wvc, k)
        residuals[i] = lossy + corr
    end
end


function decorrelate_pass!(data::Vector{Int32}, term::Int, weight::Int32, delta::Int32)
    # term 1-8 are standard delays, 17/18 are special stereo decorrelation
    @inbounds for i in (term + 1):length(data)
        # 1. Apply prediction
        sam_prev = data[i - term]
        prediction = (Int64(weight) * sam_prev + 512) >> 10
        data[i] += Int32(prediction)
        
        # 2. Update weight (Sign-Sign LMS)
        if data[i] != 0 && sam_prev != 0
            # If signs match, increment weight; else decrement
            if (data[i] ^ sam_prev) >= 0
                weight += delta
            else
                weight -= delta
            end
        end
    end
    return weight
end


=#

#=
# Metadata IDs from WavPack 5 specification
const ID_DECORR_TERMS   = 0x2
const ID_DECORR_WEIGHTS = 0x3
const ID_WV_BITSTREAM   = 0xa
const ID_WVC_BITSTREAM  = 0xb

struct MetadataChunk
    id::UInt8
    ptr::Ptr{UInt16}
    word_count::Int
end

function parse_metadata(block_ptr::Ptr{UInt8}, block_size::Int)
    # Start after the 32-byte WavPack header
    pos = 32
    chunks = MetadataChunk[]
    
    while pos < block_size
        id_byte = unsafe_load(block_ptr + pos)
        size_byte = unsafe_load(block_ptr + pos + 1)
        
        id = id_byte & 0x3F
        is_large = (id_byte & 0x80) != 0
        
        # Determine actual data size and offset
        if !is_large
            word_count = Int(size_byte)
            data_offset = pos + 2
            next_pos = data_offset + (word_count * 2)
        else
            # Large blocks use 3 bytes for size
            size_lo = UInt32(size_byte)
            size_hi = unsafe_load(reinterpret(Ptr{UInt16}, block_ptr + pos + 2))
            word_count = Int(size_lo | (size_hi << 8))
            data_offset = pos + 4
            next_pos = data_offset + (word_count * 2)
        end

        push!(chunks, MetadataChunk(id, reinterpret(Ptr{UInt16}, block_ptr + data_offset), word_count))
        pos = next_pos
    end
    return chunks
end

function extract_decorr_params(chunk::MetadataChunk)
    if chunk.id == ID_DECORR_TERMS
        # Format: [Term (byte 1), Delta (byte 2), ...]
        raw_bytes = unsafe_wrap(Array, reinterpret(Ptr{Int8}, chunk.ptr), chunk.word_count * 2)
        return [(term=raw_bytes[i], delta=raw_bytes[i+1]) for i in 1:2:length(raw_bytes)]
    elseif chunk.id == ID_DECORR_WEIGHTS
        # Initial signed 16-bit weights
        return unsafe_wrap(Array, reinterpret(Ptr{Int16}, chunk.ptr), chunk.word_count)
    end
end
=#

#=
function decode_hybrid_block!(
    dest::AbstractVector{Sample{N, T}}, 
    wv_ptr::Ptr{UInt8}, 
    wvc_ptr::Ptr{UInt8}, 
    wv_size::Int, 
    wvc_size::Int
) where {N, T}
    # 1. Parse Headers (Verify synchronization)
    wv_hdr  = parse_header(wv_ptr)
    wvc_hdr = parse_header(wvc_ptr)
    
    if wv_hdr.block_index != wvc_hdr.block_index
        error("WV and WVC files are out of sync at block $(wv_hdr.block_index)")
    end

    # 2. Parse Metadata (Get terms and weights)
    wv_metadata = parse_metadata(wv_ptr, wv_size)
    wvc_metadata = parse_metadata(wvc_ptr, wvc_size)

    # 3. Locate Bitstreams
    # ID 0xa = WV Bitstream, ID 0xb = WVC Correction Bitstream
    wv_chunk  = find_metadata_chunk(wv_metadata, 0xa)
    wvc_chunk = find_metadata_chunk(wvc_metadata, 0xb)

    # Initialize Bit Readers
    br_wv  = WavpackBitReader(wv_chunk.ptr,  0, 0, 0, wv_chunk.word_count * 2)
    br_wvc = WavpackBitReader(wvc_chunk.ptr, 0, 0, 0, wvc_chunk.word_count * 2)

    # 4. Extract Decorrelation Parameters (from WV metadata)
    terms   = extract_decorr_params(find_metadata_chunk(wv_metadata, 0x2))
    weights = extract_decorr_params(find_metadata_chunk(wv_metadata, 0x3))

    # 5. The Reconstruction Loop (Hybrid Lossless Core)
    n_samples = wv_hdr.block_samples
    residuals = Vector{Int32}(undef, n_samples)
    
    # Process per channel (Simplified for Mono/Stereo)
    for ch in 1:N
        # Step A: Entropy Decode (Bit-Perfect Reassembly)
        reconstruct_hybrid!(residuals, br_wv, br_wvc)
        
        # Step B: Decorrelate (LMS Filtering)
        # Apply filters in reverse order as specified in metadata
        for i in length(terms):-1:1
            decorrelate_pass!(residuals, terms[i].term, weights[i], terms[i].delta)
        end
        
        # Step C: Write to Destination Buffer
        # (Handling potential fixed-point or float conversion)
        write_pcm_to_dest!(dest, residuals, ch)
    end
end

function audioread_wv_hybrid(wv_path::String, wvc_path::String)
    wv_data, wv_raw_ptr   = malloc_read(wv_path)
    wvc_data, wvc_raw_ptr = malloc_read(wvc_path)
    
    # 1. Map out all block offsets in both files first
    wv_blocks  = map_blocks(wv_data)
    wvc_blocks = map_blocks(wvc_data)
    
    # 2. Allocate the final output array
    total_samples = get_total_samples(wv_data)
    output = Vector{Sample{2, Float32}}(undef, total_samples)

    # 3. Parallel Decompression
    Threads.@threads for i in 1:length(wv_blocks)
        decode_hybrid_block!(
            view(output, wv_blocks[i].range),
            wv_raw_ptr + wv_blocks[i].offset,
            wvc_raw_ptr + wvc_blocks[i].offset,
            wv_blocks[i].size,
            wvc_blocks[i].size
        )
    end
    
    return output
end

=#


#=
@inline function get_rice_k(m::UInt32)
    # Fast bit-scan to find the 'magnitude' of the median
    k = 0
    while (m >>= 1) > 0
        k += 1
    end
    return k > 24 ? 24 : k # Cap at 24 bits
end

@inline function decode_rice_adaptive!(br::WavpackBitReader, m::Vector{UInt32})
    k = get_rice_k(m[1])
    
    # 1. Get unary prefix (number of '0's before a '1')
    count = 0
    while get_bits(br, 1) == 0
        count += 1
    end
    
    # 2. Get binary body of k bits
    body = get_bits(br, k)
    val = UInt32((count << k) | body)
    
    # 3. Update Adaptive Medians (The "Secret Sauce")
    # This logic matches the official WavPack 5 specification for medians
    if val == 0
        m[1] -= ((m[1] + 3) >> 2)
    else
        m[1] += ((val - m[1] + 3) >> 2)
    end
    
    # 4. Handle sign (bit 0 is sign)
    res = (val & 1) != 0 ? -Int32(val >> 1) : Int32(val >> 1)
    return res
end

function reconstruct_hybrid!(
    residuals::Vector{Int32}, 
    br_wv::WavpackBitReader, 
    br_wvc::WavpackBitReader,
    medians::Vector{UInt32} # [m0, m1, m2]
)
    @inbounds for i in 1:length(residuals)
        # Decode Lossy part (from .wv)
        lossy = decode_rice_adaptive!(br_wv, medians)
        
        # Decode Correction part (from .wvc)
        # Note: The correction stream uses the same median state
        corr = decode_rice_adaptive!(br_wvc, medians)
        
        # Bit-perfect sum
        residuals[i] = lossy + corr
    end
end
=#

#=
function process_block(wv_ptr::Ptr{UInt8}, wvc_ptr::Ptr{UInt8}, n_samples::Int)
    # Pre-allocate medians for this block (Avoid GC by using a small fixed array)
    # Initial medians are usually stored in the block metadata or 
    # defaulted to 128 if not present.
    medians = UInt32[128, 128, 128] 
    
    residuals = Vector{Int32}(undef, n_samples)
    
    # ... Set up br_wv and br_wvc ...

    reconstruct_hybrid!(residuals, br_wv, br_wvc, medians)
    
    # Now residuals contains bit-perfect PCM ready for the decorrelator
    return residuals
end

=#
