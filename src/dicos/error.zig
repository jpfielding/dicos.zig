/// Errors from codec encode/decode operations.
pub const CodecError = error{
    /// I/O error during codec operation.
    IoError,
    /// The compressed data is malformed or truncated.
    InvalidData,
    /// The codec does not support this operation or format.
    Unsupported,
    /// The number of decoded pixels does not match the expected dimensions.
    DimensionMismatch,
    /// End of stream reached unexpectedly.
    EndOfStream,
    /// Out of memory.
    OutOfMemory,
};

/// Errors from DICOS file operations.
pub const DicosError = error{
    /// I/O error.
    IoError,
    /// The file is not a valid DICOS/DICOM Part-10 file.
    InvalidFile,
    /// A required attribute is missing from the dataset.
    MissingAttribute,
    /// An attribute has an invalid value.
    InvalidValue,
    /// The transfer syntax is not supported.
    UnsupportedTransferSyntax,
    /// Validation constraint violated.
    ValidationError,
    /// End of stream reached unexpectedly.
    EndOfStream,
    /// Out of memory.
    OutOfMemory,
} || CodecError;
