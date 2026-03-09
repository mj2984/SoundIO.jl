module SoundIO
using Libdl, libsoundio_jll
include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")

export SoundIOContext, SoundIODevice, SoundIOOutStream, PlaybackState,
       enumerate_devices!, play_audio, FrozenAudioBuffer
end
