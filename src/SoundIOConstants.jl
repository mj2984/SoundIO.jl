# Little Endian (3 bytes), Big Endian
# Pre-resolving the memory address of the function to bypass lookup in the shared library's symbol table.
const soundio_wait_events_ptr = Libdl.dlsym(Libdl.dlopen(libsoundio), :soundio_wait_events)
const SoundIoFormats = Dict{Symbol, Int32}(
    :Invalid        => 0,
    :Int8           => 1,
    :UInt8          => 2,
    :Int16Little    => 3,
    :Int16Big       => 4,
    :UInt16Little   => 5,
    :UInt16Big      => 6,
    :Int24Little    => 7,
    :Int24Big       => 8,
    :UInt24Little   => 9,
    :UInt24Big      => 10,
    :Int32Little    => 11,
    :Int32Big       => 12,
    :UInt32Little   => 13,
    :UInt32Big      => 14,
    :Float32Little  => 15,
    :Float32Big     => 16,
    :Float64Little  => 17,
    :Float64Big     => 18,
)
