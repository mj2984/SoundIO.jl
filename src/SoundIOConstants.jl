# Pre-resolving the memory address of the function to bypass lookup in the shared library's symbol table.
const libsoundio = libsoundio_jll.libsoundio_path
#const libsoundio = "C:\\Users\\manue\\Downloads\\libsoundio_build\\products\\libsoundio.v2.0.0.x86_64-w64-mingw32\\bin\\libsoundio.dll"
const soundio_wait_events_ptr = Libdl.dlsym(Libdl.dlopen(libsoundio), :soundio_wait_events)
const soundio_outstream_begin_write_ptr = Libdl.dlsym(Libdl.dlopen(libsoundio), :soundio_outstream_begin_write)
const soundio_outstream_end_write_ptr = Libdl.dlsym(Libdl.dlopen(libsoundio), :soundio_outstream_end_write)
const SoundIOBackendMemoryOffsetBytes = 32
const SoundIOBackendNone = 0
const SOUNDIO_DEVICE_FORMATS_OFFSET = 112
const SOUNDIO_DEVICE_FORMAT_COUNT_OFFSET = 120
# Little Endian (3 bytes), Big Endian
const SoundIoFormats = Dict{Symbol, Int32}(
    :Invalid        => 0 ,
    :Int8           => 1 , :UInt8          => 2 ,
    :Int16Little    => 3 , :Int16Big       => 4 , :UInt16Little   => 5 , :UInt16Big      => 6 ,
    :Int24Little    => 7 , :Int24Big       => 8 , :UInt24Little   => 9 , :UInt24Big      => 10,
    :Int32Little    => 11, :Int32Big       => 12, :UInt32Little   => 13, :UInt32Big      => 14,
    :Float32Little  => 15, :Float32Big     => 16,
    :Float64Little  => 17, :Float64Big     => 18,
)
const SoundIoErrorMap = Dict{Int32, Symbol}(
    0  => :Success,
    1  => :OutOfMemory,
    2  => :BackendInitializationFailed,
    3  => :SystemResourcesUnavailable,
    4  => :OpeningDeviceFailed,
    5  => :DeviceNotFound,
    6  => :InvalidParameter,
    7  => :BackendUnavailable,
    8  => :StreamingError, # Unrecoverable
    9  => :IncompatibleDeviceParameters,
    10 => :NoSuchClient,
    11 => :IncompatibleBackend,
    12 => :BackendDisconnected,
    13 => :Interrupted,
    14 => :BufferUnderflow,
    15 => :EncodingError,
)
