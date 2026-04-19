# Pre-resolving the memory address of the function to bypass lookup in the shared library's symbol table.
const libsoundio = libsoundio_jll.libsoundio_path
const SoundIOBackendMemoryOffsetBytes = 32
const SoundIOBackendNone = 0
# Little Endian (3 bytes), Big Endian
const SoundIoFormats = Dict{Symbol, Cint}(
    :Invalid        => 0 ,
    :Int8           => 1 , :UInt8          => 2 ,
    :Int16Little    => 3 , :Int16Big       => 4 , :UInt16Little   => 5 , :UInt16Big      => 6 ,
    :Int24Little    => 7 , :Int24Big       => 8 , :UInt24Little   => 9 , :UInt24Big      => 10,
    :Int32Little    => 11, :Int32Big       => 12, :UInt32Little   => 13, :UInt32Big      => 14,
    :Float32Little  => 15, :Float32Big     => 16,
    :Float64Little  => 17, :Float64Big     => 18,
)
const FORMAT_LOOKUP = Dict(val => sym for (sym, val) in SoundIoFormats)
const SoundIoErrorMap = Dict{Cint, Symbol}(
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
const CallbackStopped::Int8 = 0
const CallbackStatusReady::Int8 = 1
const CallbackJuliaDone::Int8 = 2
#const CallbackInactive::Int8 = -1
const CallbackStatusEnumerations = Dict{Int8,Symbol}(
    CallbackStopped => :callback_stopped,
    CallbackStatusReady => :callback_ready,
    CallbackJuliaDone => :julia_done,
    # Use negative of SoundIoErrorMap for error status.
    #CallbackInactive => :inactive, # completed <
    #-2 => :streaming_error
)
