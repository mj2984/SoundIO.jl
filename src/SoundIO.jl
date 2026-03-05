module SoundIO
using Libdl
using libsoundio_jll
const libsoundio = libsoundio_jll.libsoundio_path

include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")

export SoundIOContext, SoundIODevice, SoundIOOutStream, PlaybackState,
       enumerate_devices!, open_outstream_direct, wait_events, play_audio
end
