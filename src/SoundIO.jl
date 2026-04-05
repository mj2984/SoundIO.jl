# SoundIO.jl - Julia bindings for libsoundio
# Copyright (c) 2026 mj2984. Licensed under the MIT License.
# libsoundio is Copyright (c) 2015 Andrew Kelley.
module SoundIO
using Libdl, libsoundio_jll, FixedPointNumbers, SamplesCore
include("SoundIOConstants.jl")
include("SoundIOStructs.jl")
include("SoundIOPrettyPrintMethods.jl")
include("SoundIOMethods.jl")
include("SoundIOBaseCallbacks.jl")
include("SoundIOGlobals.jl")
export SoundIOContext, SoundIODevice, SoundIOOutStream, FrozenAudioStream, FrozenAudioExchange,
       SoundIOSynchronizer, AudioCallbackSynchronizer,
       is_connected_unsafe, is_connected,open_unsafe!, open!, connect_unsafe!, connect!,
       disconnect_unsafe!, disconnect!, flush_events_unsafe!, flush_events!, wait_unsafe,
       enumerate_devices_unsafe!, enumerate_devices!, supported_formats,
       start!, CallbackStopped, CallbackJuliaDone, CallbackStatusReady,
       acquire_sound_buffer_ptr, acquire_sound_buffer, release_sound_buffer, halt_sound_buffer,
       destroy_sound_stream_unsafe, destroy_sound_stream!, AudioCallbackMessage,
       enumerate_sound_devices!, list_sound_devices
end
