use crate::error::SlimgBridgeError;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatInfo {
    pub id: String,
    pub extension: String,
    pub can_encode: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ImageMetadata {
    pub width: u32,
    pub height: u32,
    pub format: String,
    pub file_size: Option<u64>,
    pub has_transparency: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaletteRecommendation {
    On,
    Review,
    Off,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PaletteSuitability {
    pub unique_color_count: u32,
    pub unique_color_count_exceeded: bool,
    pub top_256_color_coverage: f64,
    pub has_alpha: bool,
    pub recommendation: PaletteRecommendation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PreviewResult {
    pub encoded_bytes: Vec<u8>,
    pub artifact_id: String,
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
    pub source_has_transparency: bool,
    pub palette_suitability: Option<PaletteSuitability>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewArtifactRequest {
    pub artifact_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedImageResult {
    pub encoded_bytes: Vec<u8>,
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RawImageResult {
    pub rgba_bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub difference_stats: Option<RawImageDifferenceStats>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RawImageDifferenceStats {
    pub mean: f64,
    pub top_10_percent: f64,
    pub top_1_percent: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessResult {
    pub output_path: String,
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub original_size: u64,
    pub new_size: u64,
    pub did_write: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchItemResult {
    pub input_path: String,
    pub success: bool,
    pub result: Option<ProcessResult>,
    pub error: Option<SlimgBridgeError>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchJobHandle {
    pub job_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnalyzeFileJobHandle {
    pub job_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchJobState {
    Running,
    CancelRequested,
    Completed,
    Canceled,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchJobSnapshot {
    pub job_id: String,
    pub state: BatchJobState,
    pub total_count: u32,
    pub completed_count: u32,
    pub current_input_path: Option<String>,
    pub results: Vec<BatchItemResult>,
    pub error: Option<SlimgBridgeError>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnalyzeSampleResult {
    pub quality: u8,
    pub temp_output_path: String,
    pub encoded_bytes: Vec<u8>,
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
    pub pixel_match: Option<f64>,
    pub ms_ssim: Option<f64>,
    pub ssimulacra2: Option<f64>,
    pub artifact_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnalyzeFileRequest {
    pub input_path: String,
    pub operation: ImageOperation,
    pub qualities: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnalyzeFileJobSnapshot {
    pub job_id: String,
    pub state: BatchJobState,
    pub total_count: u32,
    pub completed_count: u32,
    pub current_quality: Option<u8>,
    pub results: Vec<AnalyzeSampleResult>,
    pub error: Option<SlimgBridgeError>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ImageOperation {
    Convert(ConvertOptions),
    Optimize(OptimizeOptions),
    Resize(ResizeOptions),
    Crop(CropOptions),
    Extend(ExtendOptions),
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProcessFileRequest {
    pub input_path: String,
    pub output_path: Option<String>,
    pub overwrite: bool,
    pub preserve_file_dates: bool,
    pub preserve_exif: bool,
    pub preserve_color_profile: bool,
    pub operation: ImageOperation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProcessBytesRequest {
    pub data: Vec<u8>,
    pub operation: ImageOperation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BatchProcessRequest {
    pub input_paths: Vec<String>,
    pub output_dir: Option<String>,
    pub overwrite: bool,
    pub operation: ImageOperation,
    pub continue_on_error: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProcessFileBatchRequest {
    pub requests: Vec<ProcessFileRequest>,
    pub continue_on_error: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PreviewFileRequest {
    pub input_path: String,
    pub operation: ImageOperation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvertOptions {
    pub target_format: String,
    pub quality: u8,
    pub effort: Option<u8>,
    pub png_palette: Option<PngPaletteMode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OptimizeOptions {
    pub quality: u8,
    pub effort: Option<u8>,
    pub png_palette: Option<PngPaletteMode>,
    pub write_only_if_smaller: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PngPaletteMode {
    Off,
    Auto,
    On,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResizeSpec {
    Width { value: u32 },
    Height { value: u32 },
    Exact { width: u32, height: u32 },
    Fit { max_width: u32, max_height: u32 },
    Scale { factor: f64 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResizeOptions {
    pub resize: ResizeSpec,
    pub target_format: Option<String>,
    pub quality: u8,
    pub effort: Option<u8>,
    pub png_palette: Option<PngPaletteMode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CropSpec {
    Region {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    },
    AspectRatio {
        width: u32,
        height: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CropOptions {
    pub crop: CropSpec,
    pub target_format: Option<String>,
    pub quality: u8,
    pub effort: Option<u8>,
    pub png_palette: Option<PngPaletteMode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExtendSpec {
    AspectRatio { width: u32, height: u32 },
    Size { width: u32, height: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FillSpec {
    Solid { r: u8, g: u8, b: u8, a: u8 },
    Transparent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtendOptions {
    pub extend: ExtendSpec,
    pub fill: Option<FillSpec>,
    pub target_format: Option<String>,
    pub quality: u8,
    pub effort: Option<u8>,
    pub png_palette: Option<PngPaletteMode>,
}

impl ImageOperation {
    pub(crate) fn suffix(&self) -> &'static str {
        match self {
            Self::Convert(_) => "converted",
            Self::Optimize(_) => "optimized",
            Self::Resize(_) => "resized",
            Self::Crop(_) => "cropped",
            Self::Extend(_) => "extended",
        }
    }

    pub(crate) fn with_quality(&self, quality: u8) -> Self {
        match self {
            Self::Convert(options) => Self::Convert(ConvertOptions {
                target_format: options.target_format.clone(),
                quality,
                effort: options.effort,
                png_palette: options.png_palette,
            }),
            Self::Optimize(options) => Self::Optimize(OptimizeOptions {
                quality,
                effort: options.effort,
                png_palette: options.png_palette,
                write_only_if_smaller: options.write_only_if_smaller,
            }),
            Self::Resize(options) => Self::Resize(ResizeOptions {
                resize: options.resize.clone(),
                target_format: options.target_format.clone(),
                quality,
                effort: options.effort,
                png_palette: options.png_palette,
            }),
            Self::Crop(options) => Self::Crop(CropOptions {
                crop: options.crop.clone(),
                target_format: options.target_format.clone(),
                quality,
                effort: options.effort,
                png_palette: options.png_palette,
            }),
            Self::Extend(options) => Self::Extend(ExtendOptions {
                extend: options.extend.clone(),
                fill: options.fill.clone(),
                target_format: options.target_format.clone(),
                quality,
                effort: options.effort,
                png_palette: options.png_palette,
            }),
        }
    }
}

impl PngPaletteMode {
    pub(crate) fn to_core(self) -> slimg_core::PngPaletteMode {
        match self {
            Self::Off => slimg_core::PngPaletteMode::Off,
            Self::Auto => slimg_core::PngPaletteMode::Auto,
            Self::On => slimg_core::PngPaletteMode::On,
        }
    }
}

impl From<slimg_core::PaletteRecommendation> for PaletteRecommendation {
    fn from(value: slimg_core::PaletteRecommendation) -> Self {
        match value {
            slimg_core::PaletteRecommendation::On => Self::On,
            slimg_core::PaletteRecommendation::Review => Self::Review,
            slimg_core::PaletteRecommendation::Off => Self::Off,
        }
    }
}

impl From<slimg_core::PaletteStats> for PaletteSuitability {
    fn from(value: slimg_core::PaletteStats) -> Self {
        Self {
            unique_color_count: value.unique_color_count,
            unique_color_count_exceeded: value.unique_color_count_exceeded,
            top_256_color_coverage: value.top_256_color_coverage,
            has_alpha: value.has_alpha,
            recommendation: value.recommendation.into(),
        }
    }
}
