const std = @import("std");

/// A DICOM/DICOS tag consisting of a group number and element number.
///
/// Tags are ordered first by group, then by element, matching the on-disk
/// ordering required by the DICOM file format.
pub const Tag = packed struct(u32) {
    element: u16,
    group: u16,

    pub fn init(group: u16, element: u16) Tag {
        return .{ .group = group, .element = element };
    }

    /// Returns `true` if this is a private tag (odd group number).
    pub fn isPrivate(self: Tag) bool {
        return self.group % 2 == 1;
    }

    /// Returns `true` if this tag is in the File Meta Information group (0002).
    pub fn isGroup0002(self: Tag) bool {
        return self.group == 0x0002;
    }

    /// Returns a human-readable name for well-known tags, or an empty string.
    pub fn name(self: Tag) []const u8 {
        return tagNameLookup(@as(u32, @bitCast(self)));
    }

    /// Format as "(GGGG,EEEE)" for display.
    pub fn format(self: Tag, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({X:0>4},{X:0>4})", .{ self.group, self.element });
    }

    /// Order function for use with std.sort and TreeMap.
    pub fn order(a: Tag, b: Tag) std.math.Order {
        const ai: u32 = @bitCast(a);
        const bi: u32 = @bitCast(b);
        return std.math.order(ai, bi);
    }
};

// ---------------------------------------------------------------------------
// File Meta Information (Group 0002)
// ---------------------------------------------------------------------------
pub const FILE_META_INFORMATION_GROUP_LENGTH = Tag.init(0x0002, 0x0000);
pub const FILE_META_INFORMATION_VERSION = Tag.init(0x0002, 0x0001);
pub const MEDIA_STORAGE_SOP_CLASS_UID = Tag.init(0x0002, 0x0002);
pub const MEDIA_STORAGE_SOP_INSTANCE_UID = Tag.init(0x0002, 0x0003);
pub const TRANSFER_SYNTAX_UID = Tag.init(0x0002, 0x0010);
pub const IMPLEMENTATION_CLASS_UID = Tag.init(0x0002, 0x0012);
pub const IMPLEMENTATION_VERSION_NAME = Tag.init(0x0002, 0x0013);
pub const SPECIFIC_CHARACTER_SET = Tag.init(0x0008, 0x0005);

// ---------------------------------------------------------------------------
// Patient Module (Group 0010)
// ---------------------------------------------------------------------------
pub const PATIENT_NAME = Tag.init(0x0010, 0x0010);
pub const PATIENT_ID = Tag.init(0x0010, 0x0020);
pub const PATIENT_BIRTH_DATE = Tag.init(0x0010, 0x0030);
pub const PATIENT_SEX = Tag.init(0x0010, 0x0040);
pub const PATIENT_AGE = Tag.init(0x0010, 0x1010);
pub const PATIENT_COMMENTS = Tag.init(0x0010, 0x4000);

// ---------------------------------------------------------------------------
// General Study Module (Groups 0008, 0020)
// ---------------------------------------------------------------------------
pub const STUDY_DATE = Tag.init(0x0008, 0x0020);
pub const STUDY_TIME = Tag.init(0x0008, 0x0030);
pub const ACCESSION_NUMBER = Tag.init(0x0008, 0x0050);
pub const STUDY_DESCRIPTION = Tag.init(0x0008, 0x1030);
pub const STUDY_INSTANCE_UID = Tag.init(0x0020, 0x000D);
pub const STUDY_ID = Tag.init(0x0020, 0x0010);

// ---------------------------------------------------------------------------
// General Series Module
// ---------------------------------------------------------------------------
pub const MODALITY = Tag.init(0x0008, 0x0060);
pub const SERIES_INSTANCE_UID = Tag.init(0x0020, 0x000E);
pub const SERIES_NUMBER = Tag.init(0x0020, 0x0011);
pub const INSTANCE_NUMBER = Tag.init(0x0020, 0x0013);
pub const SERIES_DESCRIPTION = Tag.init(0x0008, 0x103E);
pub const SERIES_DATE = Tag.init(0x0008, 0x0021);
pub const SERIES_TIME = Tag.init(0x0008, 0x0031);
pub const PRESENTATION_INTENT_TYPE = Tag.init(0x0008, 0x0068);

// ---------------------------------------------------------------------------
// General Equipment Module
// ---------------------------------------------------------------------------
pub const MANUFACTURER = Tag.init(0x0008, 0x0070);
pub const INSTITUTION_NAME = Tag.init(0x0008, 0x0080);
pub const STATION_NAME = Tag.init(0x0008, 0x1010);
pub const MANUFACTURER_MODEL_NAME = Tag.init(0x0008, 0x1090);
pub const DEVICE_SERIAL_NUMBER = Tag.init(0x0018, 0x1000);
pub const SOFTWARE_VERSIONS = Tag.init(0x0018, 0x1020);

// ---------------------------------------------------------------------------
// SOP Common Module
// ---------------------------------------------------------------------------
pub const SOP_CLASS_UID = Tag.init(0x0008, 0x0016);
pub const SOP_INSTANCE_UID = Tag.init(0x0008, 0x0018);
pub const INSTANCE_CREATION_DATE = Tag.init(0x0008, 0x0012);
pub const INSTANCE_CREATION_TIME = Tag.init(0x0008, 0x0013);

// ---------------------------------------------------------------------------
// X-Ray Acquisition Parameters
// ---------------------------------------------------------------------------
pub const KVP = Tag.init(0x0018, 0x0060);
pub const IMAGE_COMMENTS = Tag.init(0x0020, 0x4000);

// ---------------------------------------------------------------------------
// Frame of Reference Module
// ---------------------------------------------------------------------------
pub const FRAME_OF_REFERENCE_UID = Tag.init(0x0020, 0x0052);
pub const POSITION_REFERENCE_INDICATOR = Tag.init(0x0020, 0x1040);

// ---------------------------------------------------------------------------
// Image Pixel Module (Group 0028)
// ---------------------------------------------------------------------------
pub const SAMPLES_PER_PIXEL = Tag.init(0x0028, 0x0002);
pub const PHOTOMETRIC_INTERPRETATION = Tag.init(0x0028, 0x0004);
pub const ROWS = Tag.init(0x0028, 0x0010);
pub const COLUMNS = Tag.init(0x0028, 0x0011);
pub const BITS_ALLOCATED = Tag.init(0x0028, 0x0100);
pub const BITS_STORED = Tag.init(0x0028, 0x0101);
pub const HIGH_BIT = Tag.init(0x0028, 0x0102);
pub const PIXEL_REPRESENTATION = Tag.init(0x0028, 0x0103);
pub const PIXEL_DATA = Tag.init(0x7FE0, 0x0010);
pub const NUMBER_OF_FRAMES = Tag.init(0x0028, 0x0008);

// ---------------------------------------------------------------------------
// CT Image Module
// ---------------------------------------------------------------------------
pub const IMAGE_TYPE = Tag.init(0x0008, 0x0008);
pub const RESCALE_INTERCEPT = Tag.init(0x0028, 0x1052);
pub const RESCALE_SLOPE = Tag.init(0x0028, 0x1053);
pub const RESCALE_TYPE = Tag.init(0x0028, 0x1054);
pub const WINDOW_CENTER = Tag.init(0x0028, 0x1050);
pub const WINDOW_WIDTH = Tag.init(0x0028, 0x1051);
pub const WINDOW_CENTER_WIDTH_EXPLANATION = Tag.init(0x0028, 0x1055);
pub const VOI_LUT_FUNCTION = Tag.init(0x0028, 0x1056);

// ---------------------------------------------------------------------------
// Image Position / Orientation
// ---------------------------------------------------------------------------
pub const IMAGE_POSITION_PATIENT = Tag.init(0x0020, 0x0032);
pub const IMAGE_ORIENTATION_PATIENT = Tag.init(0x0020, 0x0037);
pub const SLICE_THICKNESS = Tag.init(0x0018, 0x0050);
pub const SPACING_BETWEEN_SLICES = Tag.init(0x0018, 0x0088);
pub const PIXEL_SPACING = Tag.init(0x0028, 0x0030);
pub const SLICE_LOCATION = Tag.init(0x0020, 0x1041);

// ---------------------------------------------------------------------------
// Content Date/Time
// ---------------------------------------------------------------------------
pub const CONTENT_DATE = Tag.init(0x0008, 0x0023);
pub const CONTENT_TIME = Tag.init(0x0008, 0x0033);

// ---------------------------------------------------------------------------
// Sequence Delimiters
// ---------------------------------------------------------------------------
pub const ITEM = Tag.init(0xFFFE, 0xE000);
pub const ITEM_DELIMITATION_ITEM = Tag.init(0xFFFE, 0xE00D);
pub const SEQUENCE_DELIMITATION_ITEM = Tag.init(0xFFFE, 0xE0DD);

// ---------------------------------------------------------------------------
// DICOS-Specific Tags (Group 4010) - ATD/Threat Detection
// ---------------------------------------------------------------------------
pub const OOI_TYPE = Tag.init(0x4010, 0x1012);
pub const OOI_SIZE = Tag.init(0x4010, 0x1024);
pub const PTO_REPRESENTATION_SEQUENCE = Tag.init(0x4010, 0x1011);
pub const THREAT_ROI_TYPE = Tag.init(0x4010, 0x1009);
pub const BOUNDING_POLYGON = Tag.init(0x4010, 0x101D);
pub const PTO_SEQUENCE = Tag.init(0x4010, 0x1010);
pub const BOUNDING_BOX_TOP_LEFT = Tag.init(0x4010, 0x1023);
pub const BOUNDING_BOX_BOTTOM_RIGHT = Tag.init(0x4010, 0x1024);
pub const POTENTIAL_THREAT_OBJECT_ID = Tag.init(0x4010, 0x1006);
pub const THREAT_CATEGORY_DESCRIPTION = Tag.init(0x4010, 0x1028);
pub const ATD_ASSESSMENT_PROBABILITY = Tag.init(0x4010, 0x1017);
pub const ATD_ABILITY = Tag.init(0x4010, 0x1001);
pub const ATD_ASSESSMENT_SEQUENCE = Tag.init(0x4010, 0x1015);
pub const THREAT_CONFIDENCE_SCORE = Tag.init(0x4010, 0x1016);
pub const ITD_TYPE = Tag.init(0x4010, 0x1041);
pub const ITD_SEQUENCE = Tag.init(0x4010, 0x1042);
pub const THREAT_ROI_SEQUENCE = Tag.init(0x4010, 0x1020);
pub const ABORT_REASON = Tag.init(0x4010, 0x1021);
pub const ALARM_DECISION = Tag.init(0x4010, 0x100A);
pub const NUMBER_OF_ALARM_OBJECTS = Tag.init(0x4010, 0x1014);
pub const ASSESSMENT_REQUEST_SEQUENCE = Tag.init(0x4010, 0x1027);
pub const OPERATOR_ASSESSMENT_SEQUENCE = Tag.init(0x4010, 0x1029);

// Reference Tags for TDR
pub const REFERENCED_SOP_CLASS_UID = Tag.init(0x0008, 0x1150);
pub const REFERENCED_SOP_INSTANCE_UID = Tag.init(0x0008, 0x1155);
pub const REFERENCED_SERIES_SEQUENCE = Tag.init(0x0008, 0x1115);
pub const REFERENCED_IMAGE_SEQUENCE = Tag.init(0x0008, 0x1140);

// Material Classification
pub const OOI_OWNER_TYPE = Tag.init(0x4010, 0x1018);
pub const ROUTE_SEGMENT_SEQUENCE = Tag.init(0x4010, 0x1007);
pub const SCANNING_CONFIGURATION = Tag.init(0x4010, 0x100B);
pub const EXPOSURE_SEQUENCE = Tag.init(0x4010, 0x100C);
pub const PROCESSED_BIN_NUMBER_SEQUENCE = Tag.init(0x4010, 0x100D);
pub const TOTAL_PROCESSED_BIN_NUMBER = Tag.init(0x4010, 0x100E);
pub const TRANSPORT_CLASSIFICATION_SEQUENCE = Tag.init(0x4010, 0x1026);

// OOI Owner Module Tags
pub const OOI_OWNER_ID = Tag.init(0x4010, 0x1030);
pub const OOI_OWNER_NAME = Tag.init(0x4010, 0x1031);
pub const OOI_OWNER_ID_TYPE = Tag.init(0x4010, 0x1032);
pub const OOI_OWNER_CATEGORY = Tag.init(0x4010, 0x1033);

// OOI Module Tags
pub const OOI_ID = Tag.init(0x4010, 0x1034);
pub const OOI_TYPE_ATTR = Tag.init(0x4010, 0x1035);
pub const OOI_SIZE_ATTR = Tag.init(0x4010, 0x1036);
pub const OOI_LABEL = Tag.init(0x4010, 0x1037);

// Itinerary Module Tags
pub const FLIGHT_NUMBER = Tag.init(0x4010, 0x1040);
pub const DEPARTURE_AIRPORT = Tag.init(0x4010, 0x1043);
pub const ARRIVAL_AIRPORT = Tag.init(0x4010, 0x1044);
pub const CARRIER_NAME = Tag.init(0x4010, 0x1045);
pub const CARRIER_CODE = Tag.init(0x4010, 0x1046);

// DICOS DX Detector Energy Tags
pub const LOW_ENERGY_DETECTOR = Tag.init(0x4010, 0x0001);
pub const HIGH_ENERGY_DETECTOR = Tag.init(0x4010, 0x0002);
pub const DETECTOR_BIN_NUMBER = Tag.init(0x4010, 0x0003);
pub const LOWER_ENERGY = Tag.init(0x4010, 0x0005);
pub const ENERGY_RESOLUTION = Tag.init(0x4010, 0x0006);
pub const HIGHER_ENERGY = Tag.init(0x4010, 0x0007);

// DX Detector Module Tags (Group 0018)
pub const DETECTOR_TYPE = Tag.init(0x0018, 0x7004);
pub const DETECTOR_CONFIGURATION = Tag.init(0x0018, 0x7005);
pub const DETECTOR_DESCRIPTION = Tag.init(0x0018, 0x7006);
pub const DETECTOR_ID = Tag.init(0x0018, 0x700A);
pub const DETECTOR_MANUFACTURER_NAME = Tag.init(0x0018, 0x702A);
pub const DETECTOR_MANUFACTURER_MODEL_NAME = Tag.init(0x0018, 0x702B);
pub const DETECTOR_ACTIVE_TIME = Tag.init(0x0018, 0x7014);
pub const DETECTOR_ACTIVATION_OFFSET = Tag.init(0x0018, 0x7016);
pub const DETECTOR_CONDITIONS_NOMINAL_FLAG = Tag.init(0x0018, 0x7000);
pub const DETECTOR_TEMPERATURE = Tag.init(0x0018, 0x7001);
pub const DETECTOR_ELEMENT_PHYSICAL_SIZE = Tag.init(0x0018, 0x7020);
pub const DETECTOR_ELEMENT_SPACING = Tag.init(0x0018, 0x7022);
pub const DETECTOR_ACTIVE_DIMENSIONS = Tag.init(0x0018, 0x7026);
pub const DETECTOR_BINNING = Tag.init(0x0018, 0x701A);
pub const FIELD_OF_VIEW_SHAPE = Tag.init(0x0018, 0x1147);
pub const FIELD_OF_VIEW_DIMENSIONS = Tag.init(0x0018, 0x1149);

// DX X-Ray Acquisition Tags
pub const XRAY_TUBE_CURRENT_IN_MA = Tag.init(0x0018, 0x8151);
pub const EXPOSURE_TIME_IN_MS = Tag.init(0x0018, 0x9328);
pub const DISTANCE_SOURCE_TO_DETECTOR = Tag.init(0x0018, 0x1110);
pub const DISTANCE_SOURCE_TO_PATIENT = Tag.init(0x0018, 0x1111);
pub const ESTIMATED_DOSE_SAVING = Tag.init(0x0018, 0x9324);
pub const EXPOSURE_CONTROL_MODE = Tag.init(0x0018, 0x7060);
pub const EXPOSURE_CONTROL_MODE_DESCRIPTION = Tag.init(0x0018, 0x7062);
pub const EXPOSURE_STATUS = Tag.init(0x0018, 0x7064);
pub const PHOTOTIMER_SETTING = Tag.init(0x0018, 0x7065);
pub const SENSITIVITY_VALUE = Tag.init(0x0018, 0x6000);
pub const ANODE_TARGET_MATERIAL = Tag.init(0x0018, 0x1191);
pub const BODY_PART_THICKNESS = Tag.init(0x0018, 0x11A0);
pub const COMPRESSION_FORCE = Tag.init(0x0018, 0x11A2);
pub const GRID = Tag.init(0x0018, 0x1166);
pub const FOCAL_SPOT_SIZE = Tag.init(0x0018, 0x1190);
pub const IMAGE_AND_FLUOROSCOPY_AREA_DOSE_PRODUCT = Tag.init(0x0018, 0x115E);

// CT Acquisition Parameters
pub const SCAN_OPTIONS = Tag.init(0x0018, 0x0022);
pub const DATA_COLLECTION_DIAMETER = Tag.init(0x0018, 0x0090);
pub const RECONSTRUCTION_DIAMETER = Tag.init(0x0018, 0x1100);
pub const CONVOLUTION_KERNEL = Tag.init(0x0018, 0x1210);
pub const EXPOSURE_TIME = Tag.init(0x0018, 0x1150);
pub const XRAY_TUBE_CURRENT = Tag.init(0x0018, 0x1151);
pub const EXPOSURE = Tag.init(0x0018, 0x1152);
pub const EXPOSURE_IN_MAS = Tag.init(0x0018, 0x1153);
pub const FILTER_TYPE = Tag.init(0x0018, 0x1160);
pub const GENERATOR_POWER = Tag.init(0x0018, 0x1170);
pub const FOCAL_SPOTS = Tag.init(0x0018, 0x1190);
pub const TABLE_HEIGHT = Tag.init(0x0018, 0x1130);
pub const ROTATION_DIRECTION = Tag.init(0x0018, 0x1140);
pub const GANTRY_DETECTOR_TILT = Tag.init(0x0018, 0x1120);
pub const TABLE_SPEED = Tag.init(0x0018, 0x9309);
pub const TABLE_FEED_PER_ROTATION = Tag.init(0x0018, 0x9310);
pub const SPIRAL_PITCH_FACTOR = Tag.init(0x0018, 0x9311);
pub const SINGLE_COLLIMATION_WIDTH = Tag.init(0x0018, 0x9306);
pub const TOTAL_COLLIMATION_WIDTH = Tag.init(0x0018, 0x9307);
pub const DATE_OF_LAST_CALIBRATION = Tag.init(0x0018, 0x1200);
pub const TIME_OF_LAST_CALIBRATION = Tag.init(0x0018, 0x1201);
pub const ACQUISITION_TYPE = Tag.init(0x0018, 0x9302);
pub const TUBE_ANGLE = Tag.init(0x0018, 0x9303);

// DICOS General Series Energy Tags (Group 6100)
pub const SERIES_ENERGY = Tag.init(0x6100, 0x0030);
pub const SERIES_ENERGY_DESCRIPTION = Tag.init(0x6100, 0x0031);

// Extended Image Pixel Module
pub const PLANAR_CONFIGURATION = Tag.init(0x0028, 0x0006);
pub const SMALLEST_IMAGE_PIXEL_VALUE = Tag.init(0x0028, 0x0106);
pub const LARGEST_IMAGE_PIXEL_VALUE = Tag.init(0x0028, 0x0107);
pub const PIXEL_PADDING_VALUE = Tag.init(0x0028, 0x0120);
pub const PIXEL_PADDING_RANGE_LIMIT = Tag.init(0x0028, 0x0121);
pub const LOSSY_IMAGE_COMPRESSION = Tag.init(0x0028, 0x2110);
pub const LOSSY_IMAGE_COMPRESSION_RATIO = Tag.init(0x0028, 0x2112);
pub const LUT_DESCRIPTOR = Tag.init(0x0028, 0x3002);
pub const LUT_DATA = Tag.init(0x0028, 0x3006);
pub const VOI_LUT_SEQUENCE = Tag.init(0x0028, 0x3010);
pub const MODALITY_LUT_SEQUENCE = Tag.init(0x0028, 0x3000);
pub const RED_PALETTE_COLOR_LUT_DATA = Tag.init(0x0028, 0x1201);
pub const GREEN_PALETTE_COLOR_LUT_DATA = Tag.init(0x0028, 0x1202);
pub const BLUE_PALETTE_COLOR_LUT_DATA = Tag.init(0x0028, 0x1203);

// ---------------------------------------------------------------------------
// Tag name map (compile-time)
// ---------------------------------------------------------------------------
const TagNameEntry = struct { key: u32, name: []const u8 };

const tag_name_entries = [_]TagNameEntry{
    .{ .key = @as(u32, @bitCast(FILE_META_INFORMATION_GROUP_LENGTH)), .name = "FileMetaInformationGroupLength" },
    .{ .key = @as(u32, @bitCast(FILE_META_INFORMATION_VERSION)), .name = "FileMetaInformationVersion" },
    .{ .key = @as(u32, @bitCast(MEDIA_STORAGE_SOP_CLASS_UID)), .name = "MediaStorageSOPClassUID" },
    .{ .key = @as(u32, @bitCast(MEDIA_STORAGE_SOP_INSTANCE_UID)), .name = "MediaStorageSOPInstanceUID" },
    .{ .key = @as(u32, @bitCast(TRANSFER_SYNTAX_UID)), .name = "TransferSyntaxUID" },
    .{ .key = @as(u32, @bitCast(IMPLEMENTATION_CLASS_UID)), .name = "ImplementationClassUID" },
    .{ .key = @as(u32, @bitCast(IMPLEMENTATION_VERSION_NAME)), .name = "ImplementationVersionName" },
    .{ .key = @as(u32, @bitCast(SPECIFIC_CHARACTER_SET)), .name = "SpecificCharacterSet" },
    .{ .key = @as(u32, @bitCast(PATIENT_NAME)), .name = "PatientName" },
    .{ .key = @as(u32, @bitCast(PATIENT_ID)), .name = "PatientID" },
    .{ .key = @as(u32, @bitCast(PATIENT_BIRTH_DATE)), .name = "PatientBirthDate" },
    .{ .key = @as(u32, @bitCast(PATIENT_SEX)), .name = "PatientSex" },
    .{ .key = @as(u32, @bitCast(PATIENT_AGE)), .name = "PatientAge" },
    .{ .key = @as(u32, @bitCast(PATIENT_COMMENTS)), .name = "PatientComments" },
    .{ .key = @as(u32, @bitCast(STUDY_DATE)), .name = "StudyDate" },
    .{ .key = @as(u32, @bitCast(STUDY_TIME)), .name = "StudyTime" },
    .{ .key = @as(u32, @bitCast(ACCESSION_NUMBER)), .name = "AccessionNumber" },
    .{ .key = @as(u32, @bitCast(STUDY_DESCRIPTION)), .name = "StudyDescription" },
    .{ .key = @as(u32, @bitCast(STUDY_INSTANCE_UID)), .name = "StudyInstanceUID" },
    .{ .key = @as(u32, @bitCast(STUDY_ID)), .name = "StudyID" },
    .{ .key = @as(u32, @bitCast(MODALITY)), .name = "Modality" },
    .{ .key = @as(u32, @bitCast(SERIES_INSTANCE_UID)), .name = "SeriesInstanceUID" },
    .{ .key = @as(u32, @bitCast(SERIES_NUMBER)), .name = "SeriesNumber" },
    .{ .key = @as(u32, @bitCast(INSTANCE_NUMBER)), .name = "InstanceNumber" },
    .{ .key = @as(u32, @bitCast(SERIES_DESCRIPTION)), .name = "SeriesDescription" },
    .{ .key = @as(u32, @bitCast(SERIES_DATE)), .name = "SeriesDate" },
    .{ .key = @as(u32, @bitCast(SERIES_TIME)), .name = "SeriesTime" },
    .{ .key = @as(u32, @bitCast(PRESENTATION_INTENT_TYPE)), .name = "PresentationIntentType" },
    .{ .key = @as(u32, @bitCast(MANUFACTURER)), .name = "Manufacturer" },
    .{ .key = @as(u32, @bitCast(INSTITUTION_NAME)), .name = "InstitutionName" },
    .{ .key = @as(u32, @bitCast(STATION_NAME)), .name = "StationName" },
    .{ .key = @as(u32, @bitCast(MANUFACTURER_MODEL_NAME)), .name = "ManufacturerModelName" },
    .{ .key = @as(u32, @bitCast(DEVICE_SERIAL_NUMBER)), .name = "DeviceSerialNumber" },
    .{ .key = @as(u32, @bitCast(SOFTWARE_VERSIONS)), .name = "SoftwareVersions" },
    .{ .key = @as(u32, @bitCast(SOP_CLASS_UID)), .name = "SOPClassUID" },
    .{ .key = @as(u32, @bitCast(SOP_INSTANCE_UID)), .name = "SOPInstanceUID" },
    .{ .key = @as(u32, @bitCast(INSTANCE_CREATION_DATE)), .name = "InstanceCreationDate" },
    .{ .key = @as(u32, @bitCast(INSTANCE_CREATION_TIME)), .name = "InstanceCreationTime" },
    .{ .key = @as(u32, @bitCast(SAMPLES_PER_PIXEL)), .name = "SamplesPerPixel" },
    .{ .key = @as(u32, @bitCast(PHOTOMETRIC_INTERPRETATION)), .name = "PhotometricInterpretation" },
    .{ .key = @as(u32, @bitCast(ROWS)), .name = "Rows" },
    .{ .key = @as(u32, @bitCast(COLUMNS)), .name = "Columns" },
    .{ .key = @as(u32, @bitCast(BITS_ALLOCATED)), .name = "BitsAllocated" },
    .{ .key = @as(u32, @bitCast(BITS_STORED)), .name = "BitsStored" },
    .{ .key = @as(u32, @bitCast(HIGH_BIT)), .name = "HighBit" },
    .{ .key = @as(u32, @bitCast(PIXEL_REPRESENTATION)), .name = "PixelRepresentation" },
    .{ .key = @as(u32, @bitCast(PIXEL_DATA)), .name = "PixelData" },
    .{ .key = @as(u32, @bitCast(NUMBER_OF_FRAMES)), .name = "NumberOfFrames" },
    .{ .key = @as(u32, @bitCast(IMAGE_TYPE)), .name = "ImageType" },
    .{ .key = @as(u32, @bitCast(RESCALE_INTERCEPT)), .name = "RescaleIntercept" },
    .{ .key = @as(u32, @bitCast(RESCALE_SLOPE)), .name = "RescaleSlope" },
    .{ .key = @as(u32, @bitCast(RESCALE_TYPE)), .name = "RescaleType" },
    .{ .key = @as(u32, @bitCast(WINDOW_CENTER)), .name = "WindowCenter" },
    .{ .key = @as(u32, @bitCast(WINDOW_WIDTH)), .name = "WindowWidth" },
    .{ .key = @as(u32, @bitCast(WINDOW_CENTER_WIDTH_EXPLANATION)), .name = "WindowCenterWidthExplanation" },
    .{ .key = @as(u32, @bitCast(VOI_LUT_FUNCTION)), .name = "VOILUTFunction" },
    .{ .key = @as(u32, @bitCast(IMAGE_POSITION_PATIENT)), .name = "ImagePositionPatient" },
    .{ .key = @as(u32, @bitCast(IMAGE_ORIENTATION_PATIENT)), .name = "ImageOrientationPatient" },
    .{ .key = @as(u32, @bitCast(SLICE_THICKNESS)), .name = "SliceThickness" },
    .{ .key = @as(u32, @bitCast(SPACING_BETWEEN_SLICES)), .name = "SpacingBetweenSlices" },
    .{ .key = @as(u32, @bitCast(PIXEL_SPACING)), .name = "PixelSpacing" },
    .{ .key = @as(u32, @bitCast(SLICE_LOCATION)), .name = "SliceLocation" },
    .{ .key = @as(u32, @bitCast(CONTENT_DATE)), .name = "ContentDate" },
    .{ .key = @as(u32, @bitCast(CONTENT_TIME)), .name = "ContentTime" },
    .{ .key = @as(u32, @bitCast(FRAME_OF_REFERENCE_UID)), .name = "FrameOfReferenceUID" },
    .{ .key = @as(u32, @bitCast(POSITION_REFERENCE_INDICATOR)), .name = "PositionReferenceIndicator" },
    .{ .key = @as(u32, @bitCast(KVP)), .name = "KVP" },
    .{ .key = @as(u32, @bitCast(IMAGE_COMMENTS)), .name = "ImageComments" },
    .{ .key = @as(u32, @bitCast(ITEM)), .name = "Item" },
    .{ .key = @as(u32, @bitCast(ITEM_DELIMITATION_ITEM)), .name = "ItemDelimitationItem" },
    .{ .key = @as(u32, @bitCast(SEQUENCE_DELIMITATION_ITEM)), .name = "SequenceDelimitationItem" },
    .{ .key = @as(u32, @bitCast(OOI_TYPE)), .name = "OOIType" },
    .{ .key = @as(u32, @bitCast(OOI_SIZE)), .name = "OOISize" },
    .{ .key = @as(u32, @bitCast(PTO_REPRESENTATION_SEQUENCE)), .name = "PTORepresentationSequence" },
    .{ .key = @as(u32, @bitCast(THREAT_ROI_TYPE)), .name = "ThreatROIType" },
    .{ .key = @as(u32, @bitCast(BOUNDING_POLYGON)), .name = "BoundingPolygon" },
    .{ .key = @as(u32, @bitCast(PTO_SEQUENCE)), .name = "PTOSequence" },
    .{ .key = @as(u32, @bitCast(BOUNDING_BOX_TOP_LEFT)), .name = "BoundingBoxTopLeft" },
    .{ .key = @as(u32, @bitCast(POTENTIAL_THREAT_OBJECT_ID)), .name = "PotentialThreatObjectID" },
    .{ .key = @as(u32, @bitCast(THREAT_CATEGORY_DESCRIPTION)), .name = "ThreatCategoryDescription" },
    .{ .key = @as(u32, @bitCast(ATD_ASSESSMENT_PROBABILITY)), .name = "ATDAssessmentProbability" },
    .{ .key = @as(u32, @bitCast(ATD_ABILITY)), .name = "ATDAbility" },
    .{ .key = @as(u32, @bitCast(ATD_ASSESSMENT_SEQUENCE)), .name = "ATDAssessmentSequence" },
    .{ .key = @as(u32, @bitCast(THREAT_CONFIDENCE_SCORE)), .name = "ThreatConfidenceScore" },
    .{ .key = @as(u32, @bitCast(ITD_TYPE)), .name = "ITDType" },
    .{ .key = @as(u32, @bitCast(ITD_SEQUENCE)), .name = "ITDSequence" },
    .{ .key = @as(u32, @bitCast(THREAT_ROI_SEQUENCE)), .name = "ThreatROISequence" },
    .{ .key = @as(u32, @bitCast(ABORT_REASON)), .name = "AbortReason" },
    .{ .key = @as(u32, @bitCast(ALARM_DECISION)), .name = "AlarmDecision" },
    .{ .key = @as(u32, @bitCast(NUMBER_OF_ALARM_OBJECTS)), .name = "NumberOfAlarmObjects" },
    .{ .key = @as(u32, @bitCast(ASSESSMENT_REQUEST_SEQUENCE)), .name = "AssessmentRequestSequence" },
    .{ .key = @as(u32, @bitCast(OPERATOR_ASSESSMENT_SEQUENCE)), .name = "OperatorAssessmentSequence" },
    .{ .key = @as(u32, @bitCast(REFERENCED_SOP_CLASS_UID)), .name = "ReferencedSOPClassUID" },
    .{ .key = @as(u32, @bitCast(REFERENCED_SOP_INSTANCE_UID)), .name = "ReferencedSOPInstanceUID" },
    .{ .key = @as(u32, @bitCast(REFERENCED_SERIES_SEQUENCE)), .name = "ReferencedSeriesSequence" },
    .{ .key = @as(u32, @bitCast(REFERENCED_IMAGE_SEQUENCE)), .name = "ReferencedImageSequence" },
};

fn tagNameLookup(key: u32) []const u8 {
    for (&tag_name_entries) |*entry| {
        if (entry.key == key) return entry.name;
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "tag ordering" {
    const t = std.testing;
    try t.expect(Tag.order(Tag.init(0x0002, 0x0000), Tag.init(0x0002, 0x0001)) == .lt);
    try t.expect(Tag.order(Tag.init(0x0002, 0xFFFF), Tag.init(0x0008, 0x0000)) == .lt);
    try t.expect(Tag.order(Tag.init(0x0028, 0x0010), Tag.init(0x7FE0, 0x0010)) == .lt);
}

test "tag equality" {
    const t = std.testing;
    const a = Tag.init(0x0028, 0x0010);
    try t.expectEqual(a, ROWS);
}

test "is private" {
    const t = std.testing;
    try t.expect(!ROWS.isPrivate());
    try t.expect(!PIXEL_DATA.isPrivate());
    try t.expect(Tag.init(0x4011, 0x0001).isPrivate());
    try t.expect(!OOI_TYPE.isPrivate());
}

test "is group 0002" {
    const t = std.testing;
    try t.expect(TRANSFER_SYNTAX_UID.isGroup0002());
    try t.expect(MEDIA_STORAGE_SOP_CLASS_UID.isGroup0002());
    try t.expect(!PATIENT_NAME.isGroup0002());
    try t.expect(!PIXEL_DATA.isGroup0002());
}

test "tag name lookup" {
    const t = std.testing;
    try t.expectEqualStrings("PatientName", PATIENT_NAME.name());
    try t.expectEqualStrings("Rows", ROWS.name());
    try t.expectEqualStrings("Columns", COLUMNS.name());
    try t.expectEqualStrings("PixelData", PIXEL_DATA.name());
    try t.expectEqualStrings("TransferSyntaxUID", TRANSFER_SYNTAX_UID.name());
    try t.expectEqualStrings("Modality", MODALITY.name());
    try t.expectEqualStrings("NumberOfFrames", NUMBER_OF_FRAMES.name());
    try t.expectEqualStrings("SOPClassUID", SOP_CLASS_UID.name());
}

test "unknown tag name is empty" {
    const t = std.testing;
    const unknown = Tag.init(0x9999, 0x9999);
    try t.expectEqualStrings("", unknown.name());
}

test "sequence delimiter constants" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 0xFFFE), ITEM.group);
    try t.expectEqual(@as(u16, 0xE000), ITEM.element);
    try t.expectEqual(@as(u16, 0xE00D), ITEM_DELIMITATION_ITEM.element);
    try t.expectEqual(@as(u16, 0xE0DD), SEQUENCE_DELIMITATION_ITEM.element);
}

test "dicos tags are in group 4010" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 0x4010), OOI_TYPE.group);
    try t.expectEqual(@as(u16, 0x4010), ATD_ABILITY.group);
    try t.expectEqual(@as(u16, 0x4010), ALARM_DECISION.group);
    try t.expectEqual(@as(u16, 0x4010), FLIGHT_NUMBER.group);
}
