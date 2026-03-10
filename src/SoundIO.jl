# SoundIO.jl - Julia bindings for libsoundio
# Copyright (c) 2026 mj2984. Licensed under the MIT License.
# libsoundio is Copyright (c) 2015 Andrew Kelley.
module SoundIO
using Libdl, libsoundio_jll
include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")
export SoundIOContext, SoundIODevice, SoundIOOutStream, FrozenAudioBuffer,
       SoundIOSynchronizer, AudioCallbackSynchronizer,
       is_connected_unsafe, is_connected,open_unsafe!, open!, connect_unsafe!, connect!,
       disconnect_unsafe!, disconnect!, flush_events_unsafe!, flush_events!, wait_unsafe,
       enumerate_devices_unsafe!, enumerate_devices!, play_audio, supported_formats,
       start!
end
