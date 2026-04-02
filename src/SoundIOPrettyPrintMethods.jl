function Base.show(io::IO, dev::SoundIODevice{StreamBaseType}) where {StreamBaseType}
    icon = StreamBaseType == SoundIoInputStream_C ? "🎤" : "🎧"
    mode_icon = dev.is_raw ? "🔗" : "  "
    default_mark = dev.is_default ? " ⭐" : ""
    print(io, "$icon [$mode_icon] $(dev.name)$default_mark")
    if !get(io, :compact, false)
        fmts = supported_formats(dev)
        if !isempty(fmts)
            print(io, "\n      └─ Formats: $(join(fmts, ", "))")
        end
        if !isempty(dev.streams)
            print(io, "\n      └─ Active Streams: $(length(dev.streams))")
        end
    end
end
function Base.show(io::IO, ctx::SoundIOContext)
    status = !isopen(ctx) ? "🔴 Closed" : 
             !is_connected(ctx) ? "🟡 Allocated (Disconnected)" : 
             "🟢 Connected"
    total_streams = sum(length(d.streams) for d in ctx.devices; init=0)
    println(io, "SoundIOContext($status, $(length(ctx.devices)) Devices, $total_streams Active Streams)")
    if !isempty(ctx.devices)
        for (i, dev) in enumerate(ctx.devices)
            print(io, "    $i. ")
            show(io, dev)
            i < length(ctx.devices) && println(io)
        end
    end
end
function Base.show(io::IO, s::SoundIOStream{S, T}) where {S, T}
    # Map the Int32 format back to a Symbol for the user if possible
    fmt_sym = :Unknown
    for (k, v) in SoundIoFormats
        if v == s.format
            fmt_sym = k
            break
        end
    end
    stream_type = S === SoundIoInputStream_C ? "InStream" : "OutStream"
    icon = S === SoundIoInputStream_C ? "🎙️ " : "🔊 "
    print(io, "$icon $stream_type($(s.rate)Hz, :$fmt_sym) [Ptr: $(s.ptr)]")
end
