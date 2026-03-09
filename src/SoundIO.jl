module SoundIO
using Libdl, libsoundio_jll
include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")
#include("Experimental.jl")
export SoundIOContext, SoundIODevice, SoundIOOutStream, FrozenAudioBuffer,
       is_connected_unsafe, is_connected,open_unsafe!, open!, connect_unsafe!, connect!,
       disconnect_unsafe!, disconnect!, flush_events_unsafe!, flush_events!, wait_unsafe,
       enumerate_devices_unsafe!, enumerate_devices!, play_audio, supported_formats
       #play_audio_threaded
end
