const mode_icons = Dict{Symbol,String}(:shared => " ",:raw => "🔗")
function Base.show(io::IO, dev::SoundDevice{StreamBaseType,Access}) where {StreamBaseType,Access}
    icon = StreamBaseType == InputSoundStream ? "🎤" : "🎧"
    mode_icon = mode_icons[Access]
    default_mark = dev.is_default ? " ⭐" : ""
    print(io, "$icon [$mode_icon] $(dev.name)$default_mark")
    if !get(io, :compact, false)
        if length(dev.formats) > 0
            print(io, "\n      └─ Formats: ")
            first = true
            for f_int in dev.formats
                sym = FORMAT_LOOKUP[f_int]
                if first
                    print(io, sym)
                    first = false
                else
                    print(io, ", ", sym)
                end
            end
        end
        if !isempty(dev.streams)
            print(io, "\n      └─ Active Streams: $(length(dev.streams))")
        end
    end
end
function Base.show(io::IO, ctx::SoundDeviceContext)
    status = !isopen(ctx) ? "🔴 Closed" : 
             !is_connected(ctx) ? "🟡 Allocated (Disconnected)" : 
             "🟢 Connected"
    total_streams = sum(length(d.streams) for d in ctx.devices; init=0)
    println(io, "SoundDeviceContext($status, $(length(ctx.devices)) Devices, $total_streams Active Streams)")
    if !isempty(ctx.devices)
        for (i, dev) in enumerate(ctx.devices)
            print(io, "    $i. ")
            show(io, dev)
            i < length(ctx.devices) && println(io)
        end
    end
end
function Base.show(io::IO, s::SoundDeviceStream{S, T}) where {S, T}
    # Map the Int32 format back to a Symbol for the user if possible
    fmt_sym = :Unknown
    for (k, v) in SoundDeviceFormats
        if v == s.format
            fmt_sym = k
            break
        end
    end
    stream_type = S === InputSoundStream ? "InStream" : "OutStream"
    icon = S === OutputSoundStream ? "🎙️ " : "🔊 "
    print(io, "$icon $stream_type($(s.rate)Hz, :$fmt_sym) [Ptr: $(s.ptr)]")
end
function Base.show(io::IO, layout::SoundDeviceChannelLayout)
    name = unsafe_string(layout.name)
    channel_count = layout.channel_count
    println("$name layout with $channel_count channels configured as :")
    println(layout.channels)
end
