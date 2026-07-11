use std::panic::{catch_unwind, AssertUnwindSafe};

pub use crate::error::SlimgBridgeError;
pub use crate::types::{
    AnalyzeFileJobHandle, AnalyzeFileJobSnapshot, AnalyzeFileRequest, AnalyzeSampleResult,
    BatchItemResult, BatchJobHandle, BatchJobSnapshot, BatchJobState, BatchProcessRequest,
    ColorProfileMode, ConvertOptions, CropOptions, CropSpec, EmbeddedMetadata, EncodedImageResult,
    ExtendOptions, ExtendSpec, FillSpec, FormatInfo, ImageMetadata, ImageOperation,
    OptimizeOptions, PreviewArtifactRequest, PreviewFileRequest, PreviewResult,
    ProcessBytesRequest, ProcessFileBatchRequest, ProcessFileRequest, ProcessResult,
    RawImageResult, ResizeOptions, ResizeSpec,
};

use crate::error::{panic_message, Result};

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[flutter_rust_bridge::frb(sync)]
pub fn supported_formats() -> Vec<FormatInfo> {
    crate::codec::format_info()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_timing_logs_enabled(enabled: bool) {
    crate::diagnostics::set_timing_logs_enabled(enabled);
}

pub fn inspect_file(input_path: String) -> Result<ImageMetadata> {
    with_internal(|| crate::convert::inspect_file(input_path))
}

pub fn inspect_bytes(data: Vec<u8>) -> Result<ImageMetadata> {
    with_internal(|| crate::convert::inspect_bytes(data))
}

pub fn preview_file(request: PreviewFileRequest) -> Result<PreviewResult> {
    with_internal(|| crate::preview::preview_file(request))
}

pub fn compute_preview_pixel_match_percentage(
    request: PreviewArtifactRequest,
) -> Result<Option<f64>> {
    with_internal(|| crate::metrics::compute_preview_pixel_match_percentage(request))
}

pub fn compute_preview_ms_ssim(request: PreviewArtifactRequest) -> Result<Option<f64>> {
    with_internal(|| crate::metrics::compute_preview_ms_ssim(request))
}

pub fn compute_preview_ssimulacra2(request: PreviewArtifactRequest) -> Result<Option<f64>> {
    with_internal(|| crate::metrics::compute_preview_ssimulacra2(request))
}

pub fn compute_preview_difference_image(
    request: PreviewArtifactRequest,
) -> Result<Option<RawImageResult>> {
    with_internal(|| crate::metrics::compute_preview_difference_image(request))
}

pub fn dispose_preview_artifact(artifact_id: String) -> Result<()> {
    with_internal(|| {
        crate::preview_artifacts::preview_artifact_store().remove(&artifact_id);
        Ok(())
    })
}

pub fn process_file(request: ProcessFileRequest) -> Result<ProcessResult> {
    with_internal(|| crate::convert::process_file(request))
}

pub fn process_bytes(request: ProcessBytesRequest) -> Result<EncodedImageResult> {
    with_internal(|| crate::convert::process_bytes(request))
}

pub fn process_files(request: BatchProcessRequest) -> Result<Vec<BatchItemResult>> {
    with_internal(|| crate::convert::process_files(request))
}

pub fn process_file_batch(request: ProcessFileBatchRequest) -> Result<Vec<BatchItemResult>> {
    with_internal(|| crate::convert::process_file_batch(request))
}

pub fn start_process_file_batch_job(request: ProcessFileBatchRequest) -> Result<BatchJobHandle> {
    with_internal(|| crate::batch_jobs::start_process_file_batch_job(request))
}

pub fn get_process_file_batch_job(job_id: String) -> Result<BatchJobSnapshot> {
    with_internal(|| crate::batch_jobs::get_process_file_batch_job(job_id))
}

pub fn cancel_process_file_batch_job(job_id: String) -> Result<()> {
    with_internal(|| crate::batch_jobs::cancel_process_file_batch_job(job_id))
}

pub fn dispose_process_file_batch_job(job_id: String) -> Result<()> {
    with_internal(|| crate::batch_jobs::dispose_process_file_batch_job(job_id))
}

pub fn start_analyze_file_job(request: AnalyzeFileRequest) -> Result<AnalyzeFileJobHandle> {
    with_internal(|| crate::analyze_jobs::start_analyze_file_job(request))
}

pub fn get_analyze_file_job(job_id: String) -> Result<AnalyzeFileJobSnapshot> {
    with_internal(|| crate::analyze_jobs::get_analyze_file_job(job_id))
}

pub fn cancel_analyze_file_job(job_id: String) -> Result<()> {
    with_internal(|| crate::analyze_jobs::cancel_analyze_file_job(job_id))
}

pub fn dispose_analyze_file_job(job_id: String) -> Result<()> {
    with_internal(|| crate::analyze_jobs::dispose_analyze_file_job(job_id))
}

fn with_internal<T, F>(func: F) -> Result<T>
where
    F: FnOnce() -> Result<T>,
{
    catch_unwind(AssertUnwindSafe(func)).map_err(|payload| SlimgBridgeError::Internal {
        message: panic_message(payload),
    })?
}
