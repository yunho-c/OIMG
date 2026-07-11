use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use slimg_core::{
    analyze_palette_suitability,
    codec::{get_codec, EncodeOptions},
    convert as core_convert, decode, CropMode, ExtendMode, FillColor, Format, PipelineOptions,
    PngPaletteMode as CorePngPaletteMode, ResizeMode,
};
use slimg_exec::{classify_format, HostResources, WorkloadClass};

use crate::codec::format_to_string;
use crate::error::{Result, SlimgBridgeError};
use crate::fs::{derive_output_path, safe_write_bytes, to_path_buf};
use crate::preview_artifacts::{preview_artifact_store, PreviewArtifact};
use crate::source_image::{decode_source_image, decode_source_image_with_color, SourceFormat};
use crate::types::{
    BatchItemResult, BatchProcessRequest, ColorProfileMode, ConvertOptions, CropSpec,
    EncodedImageResult, ExtendSpec, FillSpec, ImageMetadata, ImageOperation, OptimizeOptions,
    PreviewResult, ProcessBytesRequest, ProcessFileBatchRequest, ProcessFileRequest, ProcessResult,
    ResizeSpec,
};

pub(crate) fn inspect_file(input_path: String) -> Result<ImageMetadata> {
    let path = read_existing_input_path(&input_path)?;
    let data = fs::read(&path).map_err(|error| map_input_io(&path, error))?;
    let mut metadata = inspect_bytes(data)?;
    metadata.file_size = Some(fs::metadata(&path)?.len());
    Ok(metadata)
}

pub(crate) fn inspect_bytes(data: Vec<u8>) -> Result<ImageMetadata> {
    if data.is_empty() {
        return Err(SlimgBridgeError::invalid_request("data must not be empty"));
    }

    let source = decode_source_image(&data)?;
    let embedded = crate::metadata::inspect(&data);
    let image = source.image;
    Ok(ImageMetadata {
        width: image.width,
        height: image.height,
        format: source.format.id().to_string(),
        file_size: None,
        has_transparency: image.data.chunks_exact(4).any(|pixel| pixel[3] < 255),
        palette_suitability: Some(analyze_palette_suitability(&image).into()),
        color_profile: crate::metadata::embedded_summary(
            "Color profile",
            embedded.icc.as_deref(),
            embedded.icc_size,
        ),
        exif: crate::metadata::embedded_summary(
            "Camera info",
            embedded.exif.as_deref(),
            embedded.exif_size,
        ),
        metadata_size: embedded.icc_size + embedded.exif_size,
    })
}

pub(crate) fn process_bytes(request: ProcessBytesRequest) -> Result<EncodedImageResult> {
    if request.data.is_empty() {
        return Err(SlimgBridgeError::invalid_request("data must not be empty"));
    }

    let source_metadata = crate::metadata::inspect(&request.data);
    let source_format = detect_source_format(&request.data)?;
    let target_format = resolve_output_format(&request.operation, source_format)?;
    let mode = effective_color_mode(request.color_profile_mode, target_format);
    let mut output = run_operation(&request.data, &request.operation, None, mode)?;
    output.data = apply_color_metadata(
        output.data,
        target_format,
        mode,
        source_metadata.icc.as_deref(),
    )?;
    Ok(EncodedImageResult {
        encoded_bytes: output.data.clone(),
        format: format_to_string(output.format),
        width: output.width,
        height: output.height,
        size_bytes: output.data.len() as u64,
    })
}

pub(crate) fn preview_file(request: crate::types::PreviewFileRequest) -> Result<PreviewResult> {
    let total_start = Instant::now();
    crate::diagnostics::timing_log(format!(
        "preview start path={} operation={:?}",
        request.input_path, request.operation
    ));

    let result = (|| -> Result<PreviewResult> {
        let read_start = Instant::now();
        let path = read_existing_input_path(&request.input_path)?;
        let data = fs::read(&path).map_err(|error| map_input_io(&path, error))?;
        let read_elapsed = read_start.elapsed();

        let operation_start = Instant::now();
        let source_metadata = crate::metadata::inspect(&data);
        let source_format = detect_source_format(&data)?;
        let target_format = resolve_output_format(&request.operation, source_format)?;
        let mode = effective_color_mode(request.color_profile_mode, target_format);
        let source = decode_source_image_with_color(&data, mode)?;
        let output = run_preview_operation(&source.image, source.format, &request.operation, None)?;
        let operation_elapsed = operation_start.elapsed();
        crate::diagnostics::timing_log(format!(
            "preview path={} read={}ms operation={}ms input_bytes={}",
            request.input_path,
            read_elapsed.as_millis(),
            operation_elapsed.as_millis(),
            data.len()
        ));

        let encoded_bytes = apply_color_metadata(
            output.data,
            target_format,
            mode,
            source_metadata.icc.as_deref(),
        )?;
        let size_bytes = encoded_bytes.len() as u64;
        Ok(PreviewResult {
            encoded_bytes,
            artifact_id: preview_artifact_store().insert(PreviewArtifact::new(
                source.image.width,
                source.image.height,
                output.width,
                output.height,
                Arc::<[u8]>::from(source.image.data),
                Arc::<[u8]>::from(output.preview_rgba_bytes),
            )),
            format: format_to_string(output.format),
            width: output.width,
            height: output.height,
            size_bytes,
        })
    })();

    match &result {
        Ok(preview) => crate::diagnostics::timing_log(format!(
            "preview done path={} format={} size={} total={}ms",
            request.input_path,
            preview.format,
            preview.size_bytes,
            total_start.elapsed().as_millis()
        )),
        Err(error) => crate::diagnostics::timing_log(format!(
            "preview failed path={} error={} total={}ms",
            request.input_path,
            error,
            total_start.elapsed().as_millis()
        )),
    }

    result
}

pub(crate) fn process_file(request: ProcessFileRequest) -> Result<ProcessResult> {
    crate::diagnostics::timing_log(format!(
        "process start input={} output={:?} overwrite={} operation={:?}",
        request.input_path, request.output_path, request.overwrite, request.operation
    ));
    process_file_request_with_threads(request, None)
}

pub(crate) fn process_files(request: BatchProcessRequest) -> Result<Vec<BatchItemResult>> {
    let continue_on_error = request.continue_on_error;
    let items = crate::execution::build_work_items_for_process_files(request)?;
    crate::execution::execute_batch_items(items, continue_on_error)
}

pub(crate) fn process_file_batch(request: ProcessFileBatchRequest) -> Result<Vec<BatchItemResult>> {
    let continue_on_error = request.continue_on_error;
    let items = crate::execution::build_work_items_for_process_file_batch(request)?;
    crate::execution::execute_batch_items(items, continue_on_error)
}

struct OperationOutput {
    data: Vec<u8>,
    format: Format,
    width: u32,
    height: u32,
    should_write: bool,
}

pub(crate) struct PreviewOperationOutput {
    pub(crate) data: Vec<u8>,
    pub(crate) preview_rgba_bytes: Vec<u8>,
    pub(crate) format: Format,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

pub(crate) fn process_file_request_with_threads(
    request: ProcessFileRequest,
    threads: Option<usize>,
) -> Result<ProcessResult> {
    process_file_path_with_metadata(
        request.input_path,
        request.output_path,
        None,
        request.overwrite,
        request.preserve_file_dates,
        request.preserve_exif,
        request.color_profile_mode,
        request.operation,
        threads,
    )
}

pub(crate) fn process_file_path_with_threads(
    input_path: String,
    explicit_output_path: Option<String>,
    output_dir: Option<PathBuf>,
    overwrite: bool,
    operation: ImageOperation,
    threads: Option<usize>,
) -> Result<ProcessResult> {
    process_file_path_with_metadata(
        input_path,
        explicit_output_path,
        output_dir,
        overwrite,
        false,
        false,
        ColorProfileMode::Preserve,
        operation,
        threads,
    )
}

fn process_file_path_with_metadata(
    input_path: String,
    explicit_output_path: Option<String>,
    output_dir: Option<PathBuf>,
    overwrite: bool,
    preserve_file_dates: bool,
    preserve_exif: bool,
    color_profile_mode: ColorProfileMode,
    operation: ImageOperation,
    threads: Option<usize>,
) -> Result<ProcessResult> {
    let total_start = Instant::now();
    let input = read_existing_input_path(&input_path)?;
    let input_bytes = fs::read(&input).map_err(|error| map_input_io(&input, error))?;
    let source_format = detect_source_format(&input_bytes)?;
    let target_format = resolve_output_format(&operation, source_format)?;
    let color_profile_mode = effective_color_mode(color_profile_mode, target_format);
    let source_metadata = crate::metadata::inspect(&input_bytes);
    let explicit_output = explicit_output_path
        .as_deref()
        .map(|value| to_path_buf(value, "output_path"))
        .transpose()?;

    let derived_output_path = derive_output_path(
        &input,
        explicit_output.as_deref(),
        output_dir.as_deref(),
        overwrite,
        &operation,
        target_format,
    )?;

    let mut output = run_operation(&input_bytes, &operation, threads, color_profile_mode)?;
    let preserved_dates = if preserve_file_dates && output.should_write {
        crate::fs::PreservedFileDates::capture(&input)
    } else {
        None
    };
    if output.should_write {
        let exif = preserve_exif
            .then_some(source_metadata.exif.as_deref())
            .flatten();
        let baked_srgb = if color_profile_mode == ColorProfileMode::BakeToSrgb
            && supports_embedded_metadata(target_format)
        {
            Some(crate::metadata::srgb_profile_bytes()?)
        } else {
            None
        };
        let icc = match color_profile_mode {
            ColorProfileMode::Preserve => source_metadata.icc.as_deref(),
            ColorProfileMode::BakeToSrgb => baked_srgb.as_deref(),
        };
        output.data = if supports_embedded_metadata(target_format) {
            crate::metadata::write_metadata(output.data, exif, icc)?
        } else {
            output.data
        };
        if matches!(
            &operation,
            ImageOperation::Optimize(OptimizeOptions {
                write_only_if_smaller: true,
                ..
            })
        ) && output.data.len() >= input_bytes.len()
        {
            output.data = input_bytes.clone();
            output.should_write = false;
        }
    }
    crate::diagnostics::timing_log(format!(
        "process resolved input={} output={} source_format={} target_format={} should_write={} overwrite={}",
        input_path,
        derived_output_path.display(),
        source_format.id(),
        format_to_string(output.format),
        output.should_write,
        overwrite
    ));
    let final_output_path = if output.should_write {
        crate::diagnostics::timing_log(format!(
            "process write start output={} bytes={}",
            derived_output_path.display(),
            output.data.len()
        ));
        safe_write_bytes(
            &derived_output_path,
            &output.data,
            overwrite,
            preserved_dates.as_ref(),
        )?;
        crate::diagnostics::timing_log(format!(
            "process write done output={}",
            derived_output_path.display()
        ));
        derived_output_path
    } else {
        crate::diagnostics::timing_log(format!(
            "process skipped write input={} output={} reason=not-smaller-or-no-change",
            input_path,
            input.display()
        ));
        input.clone()
    };

    let result = ProcessResult {
        output_path: final_output_path.to_string_lossy().into_owned(),
        format: format_to_string(output.format),
        width: output.width,
        height: output.height,
        original_size: input_bytes.len() as u64,
        new_size: output.data.len() as u64,
        did_write: output.should_write,
    };
    crate::diagnostics::timing_log(format!(
        "process done input={} output={} did_write={} total={}ms",
        input_path,
        result.output_path,
        result.did_write,
        total_start.elapsed().as_millis()
    ));
    Ok(result)
}

fn run_operation(
    data: &[u8],
    operation: &ImageOperation,
    threads: Option<usize>,
    color_profile_mode: ColorProfileMode,
) -> Result<OperationOutput> {
    match operation {
        ImageOperation::Convert(options) => {
            convert_bytes(data, options, threads, color_profile_mode)
        }
        ImageOperation::Optimize(options) => {
            optimize_bytes(data, options, threads, color_profile_mode)
        }
        ImageOperation::Resize(options) => {
            transform_bytes(data, options.quality, color_profile_mode, |source| {
                Ok(PipelineOptions {
                    format: resolve_optional_target_format(
                        options.target_format.as_deref(),
                        source,
                    )?,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads,
                    resize: Some(map_resize_spec(&options.resize)?),
                    crop: None,
                    extend: None,
                    fill_color: None,
                })
            })
        }
        ImageOperation::Crop(options) => {
            transform_bytes(data, options.quality, color_profile_mode, |source| {
                Ok(PipelineOptions {
                    format: resolve_optional_target_format(
                        options.target_format.as_deref(),
                        source,
                    )?,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads,
                    resize: None,
                    crop: Some(map_crop_spec(&options.crop)?),
                    extend: None,
                    fill_color: None,
                })
            })
        }
        ImageOperation::Extend(options) => {
            transform_bytes(data, options.quality, color_profile_mode, |source| {
                Ok(PipelineOptions {
                    format: resolve_optional_target_format(
                        options.target_format.as_deref(),
                        source,
                    )?,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads,
                    resize: None,
                    crop: None,
                    extend: Some(map_extend_spec(&options.extend)?),
                    fill_color: map_fill_spec(options.fill.as_ref()),
                })
            })
        }
    }
}

fn supports_embedded_metadata(format: Format) -> bool {
    matches!(format, Format::Jpeg | Format::Png | Format::WebP)
}

fn effective_color_mode(requested: ColorProfileMode, target: Format) -> ColorProfileMode {
    if requested == ColorProfileMode::Preserve && !supports_embedded_metadata(target) {
        ColorProfileMode::BakeToSrgb
    } else {
        requested
    }
}

fn apply_color_metadata(
    output: Vec<u8>,
    target: Format,
    mode: ColorProfileMode,
    source_icc: Option<&[u8]>,
) -> Result<Vec<u8>> {
    if !supports_embedded_metadata(target) {
        return Ok(output);
    }
    let srgb;
    let icc = match mode {
        ColorProfileMode::Preserve => source_icc,
        ColorProfileMode::BakeToSrgb => {
            srgb = crate::metadata::srgb_profile_bytes()?;
            Some(srgb.as_slice())
        }
    };
    crate::metadata::write_metadata(output, None, icc)
}

pub(crate) fn run_preview_operation(
    image: &slimg_core::ImageData,
    source_format: SourceFormat,
    operation: &ImageOperation,
    threads: Option<usize>,
) -> Result<PreviewOperationOutput> {
    let output = match operation {
        ImageOperation::Convert(options) => {
            let quality = validate_quality(options.quality)?;
            let effort = validate_effort(options.effort)?;
            let target_format = crate::codec::parse_format(&options.target_format)?;
            let encode_threads = encode_threads_for_format(target_format, threads);
            let result = core_convert(
                image,
                &PipelineOptions {
                    format: target_format,
                    quality,
                    effort,
                    png_palette: map_png_palette(options.png_palette),
                    threads: encode_threads,
                    resize: None,
                    crop: None,
                    extend: None,
                    fill_color: None,
                },
            )?;
            (result.data, result.format, result.width, result.height)
        }
        ImageOperation::Optimize(options) => {
            let quality = validate_quality(options.quality)?;
            let effort = validate_effort(options.effort)?;
            let source_core_format = source_format.core()?;
            let codec = get_codec(source_core_format);
            let encoded = codec.encode(
                image,
                &EncodeOptions {
                    quality,
                    effort,
                    png_palette: map_png_palette(options.png_palette),
                    threads: encode_threads_for_format(source_core_format, threads),
                },
            )?;
            (encoded, source_core_format, image.width, image.height)
        }
        ImageOperation::Resize(options) => {
            let target_format =
                resolve_optional_target_format(options.target_format.as_deref(), source_format)?;
            let result = core_convert(
                image,
                &PipelineOptions {
                    format: target_format,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads: encode_threads_for_format(target_format, threads),
                    resize: Some(map_resize_spec(&options.resize)?),
                    crop: None,
                    extend: None,
                    fill_color: None,
                },
            )?;
            (result.data, result.format, result.width, result.height)
        }
        ImageOperation::Crop(options) => {
            let target_format =
                resolve_optional_target_format(options.target_format.as_deref(), source_format)?;
            let result = core_convert(
                image,
                &PipelineOptions {
                    format: target_format,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads: encode_threads_for_format(target_format, threads),
                    resize: None,
                    crop: Some(map_crop_spec(&options.crop)?),
                    extend: None,
                    fill_color: None,
                },
            )?;
            (result.data, result.format, result.width, result.height)
        }
        ImageOperation::Extend(options) => {
            let target_format =
                resolve_optional_target_format(options.target_format.as_deref(), source_format)?;
            let result = core_convert(
                image,
                &PipelineOptions {
                    format: target_format,
                    quality: validate_quality(options.quality)?,
                    effort: validate_effort(options.effort)?,
                    png_palette: map_png_palette(options.png_palette),
                    threads: encode_threads_for_format(target_format, threads),
                    resize: None,
                    crop: None,
                    extend: Some(map_extend_spec(&options.extend)?),
                    fill_color: map_fill_spec(options.fill.as_ref()),
                },
            )?;
            (result.data, result.format, result.width, result.height)
        }
    };

    let preview_rgba_bytes = preview_rgba_bytes(&output.0)?;
    Ok(PreviewOperationOutput {
        data: output.0,
        preview_rgba_bytes,
        format: output.1,
        width: output.2,
        height: output.3,
    })
}

fn convert_bytes(
    data: &[u8],
    options: &ConvertOptions,
    threads: Option<usize>,
    color_profile_mode: ColorProfileMode,
) -> Result<OperationOutput> {
    let quality = validate_quality(options.quality)?;
    let effort = validate_effort(options.effort)?;
    let target_format = crate::codec::parse_format(&options.target_format)?;
    let source = decode_source_image_with_color(data, color_profile_mode)?;
    let result = core_convert(
        &source.image,
        &PipelineOptions {
            format: target_format,
            quality,
            effort,
            png_palette: map_png_palette(options.png_palette),
            threads: encode_threads_for_format(target_format, threads),
            resize: None,
            crop: None,
            extend: None,
            fill_color: None,
        },
    )?;
    Ok(OperationOutput {
        data: result.data,
        format: result.format,
        width: result.width,
        height: result.height,
        should_write: true,
    })
}

fn optimize_bytes(
    data: &[u8],
    options: &OptimizeOptions,
    threads: Option<usize>,
    color_profile_mode: ColorProfileMode,
) -> Result<OperationOutput> {
    let quality = validate_quality(options.quality)?;
    let effort = validate_effort(options.effort)?;
    let total_start = Instant::now();

    let decode_start = Instant::now();
    let source = decode_source_image_with_color(data, color_profile_mode)?;
    let image = source.image;
    let format = source.format.core()?;
    let decode_elapsed = decode_start.elapsed();

    let encode_start = Instant::now();
    let codec = get_codec(format);
    let encoded = codec.encode(
        &image,
        &EncodeOptions {
            quality,
            effort,
            png_palette: map_png_palette(options.png_palette),
            threads: encode_threads_for_format(format, threads),
        },
    )?;
    let encode_elapsed = encode_start.elapsed();

    let should_write = !options.write_only_if_smaller || encoded.len() < data.len();

    crate::diagnostics::timing_log(format!(
        "optimize format={} quality={} decode={}ms encode={}ms total={}ms input_bytes={} output_bytes={} write={}",
        format_to_string(format),
        quality,
        decode_elapsed.as_millis(),
        encode_elapsed.as_millis(),
        total_start.elapsed().as_millis(),
        data.len(),
        encoded.len(),
        should_write
    ));

    Ok(OperationOutput {
        data: if should_write { encoded } else { data.to_vec() },
        format,
        width: image.width,
        height: image.height,
        should_write,
    })
}

fn transform_bytes<F>(
    data: &[u8],
    quality: u8,
    color_profile_mode: ColorProfileMode,
    build: F,
) -> Result<OperationOutput>
where
    F: FnOnce(SourceFormat) -> Result<PipelineOptions>,
{
    let source = decode_source_image_with_color(data, color_profile_mode)?;
    validate_quality(quality)?;
    let mut options = build(source.format)?;
    options.threads = encode_threads_for_format(options.format, options.threads);
    let result = core_convert(&source.image, &options)?;
    Ok(OperationOutput {
        data: result.data,
        format: result.format,
        width: result.width,
        height: result.height,
        should_write: true,
    })
}

fn detect_source_format(data: &[u8]) -> Result<SourceFormat> {
    Ok(decode_source_image(data)?.format)
}

fn resolve_output_format(
    operation: &ImageOperation,
    source_format: SourceFormat,
) -> Result<Format> {
    match operation {
        ImageOperation::Convert(options) => crate::codec::parse_format(&options.target_format),
        ImageOperation::Optimize(_) => source_format.core(),
        ImageOperation::Resize(options) => {
            resolve_optional_target_format(options.target_format.as_deref(), source_format)
        }
        ImageOperation::Crop(options) => {
            resolve_optional_target_format(options.target_format.as_deref(), source_format)
        }
        ImageOperation::Extend(options) => {
            resolve_optional_target_format(options.target_format.as_deref(), source_format)
        }
    }
}

fn resolve_optional_target_format(value: Option<&str>, fallback: SourceFormat) -> Result<Format> {
    match value {
        Some(format) => crate::codec::parse_format(format),
        None => fallback.core(),
    }
}

fn encode_threads_for_format(format: Format, requested: Option<usize>) -> Option<usize> {
    if requested.is_some() || classify_format(format) != WorkloadClass::InternallyThreaded {
        return requested;
    }

    Some(HostResources::current().usable_cores.min(4).max(1))
}

fn preview_rgba_bytes(encoded: &[u8]) -> Result<Vec<u8>> {
    match decode(encoded) {
        Ok((preview_image, _)) => Ok(preview_image.data),
        Err(error) => Err(error.into()),
    }
}

fn map_resize_spec(spec: &ResizeSpec) -> Result<ResizeMode> {
    match spec {
        ResizeSpec::Width { value } => {
            require_non_zero(*value, "resize width must be greater than zero")?;
            Ok(ResizeMode::Width(*value))
        }
        ResizeSpec::Height { value } => {
            require_non_zero(*value, "resize height must be greater than zero")?;
            Ok(ResizeMode::Height(*value))
        }
        ResizeSpec::Exact { width, height } => {
            require_non_zero(*width, "resize width must be greater than zero")?;
            require_non_zero(*height, "resize height must be greater than zero")?;
            Ok(ResizeMode::Exact(*width, *height))
        }
        ResizeSpec::Fit {
            max_width,
            max_height,
        } => {
            require_non_zero(*max_width, "fit max_width must be greater than zero")?;
            require_non_zero(*max_height, "fit max_height must be greater than zero")?;
            Ok(ResizeMode::Fit(*max_width, *max_height))
        }
        ResizeSpec::Scale { factor } => {
            if *factor <= 0.0 {
                return Err(SlimgBridgeError::invalid_request(
                    "resize scale factor must be greater than zero",
                ));
            }
            Ok(ResizeMode::Scale(*factor))
        }
    }
}

fn map_crop_spec(spec: &CropSpec) -> Result<CropMode> {
    match spec {
        CropSpec::Region {
            x,
            y,
            width,
            height,
        } => {
            require_non_zero(*width, "crop width must be greater than zero")?;
            require_non_zero(*height, "crop height must be greater than zero")?;
            Ok(CropMode::Region {
                x: *x,
                y: *y,
                width: *width,
                height: *height,
            })
        }
        CropSpec::AspectRatio { width, height } => {
            require_non_zero(*width, "crop aspect width must be greater than zero")?;
            require_non_zero(*height, "crop aspect height must be greater than zero")?;
            Ok(CropMode::AspectRatio {
                width: *width,
                height: *height,
            })
        }
    }
}

fn map_extend_spec(spec: &ExtendSpec) -> Result<ExtendMode> {
    match spec {
        ExtendSpec::AspectRatio { width, height } => {
            require_non_zero(*width, "extend aspect width must be greater than zero")?;
            require_non_zero(*height, "extend aspect height must be greater than zero")?;
            Ok(ExtendMode::AspectRatio {
                width: *width,
                height: *height,
            })
        }
        ExtendSpec::Size { width, height } => {
            require_non_zero(*width, "extend width must be greater than zero")?;
            require_non_zero(*height, "extend height must be greater than zero")?;
            Ok(ExtendMode::Size {
                width: *width,
                height: *height,
            })
        }
    }
}

fn map_fill_spec(spec: Option<&FillSpec>) -> Option<FillColor> {
    spec.map(|fill| match fill {
        FillSpec::Solid { r, g, b, a } => FillColor::Solid([*r, *g, *b, *a]),
        FillSpec::Transparent => FillColor::Transparent,
    })
}

fn validate_quality(quality: u8) -> Result<u8> {
    if quality > 100 {
        return Err(SlimgBridgeError::invalid_request(
            "quality must be between 0 and 100",
        ));
    }
    Ok(quality)
}

fn validate_effort(effort: Option<u8>) -> Result<Option<u8>> {
    if effort.is_some_and(|value| value > 100) {
        return Err(SlimgBridgeError::invalid_request(
            "effort must be between 0 and 100",
        ));
    }
    Ok(effort)
}

fn map_png_palette(mode: Option<crate::types::PngPaletteMode>) -> CorePngPaletteMode {
    mode.map(crate::types::PngPaletteMode::to_core)
        .unwrap_or_default()
}

fn require_non_zero(value: u32, message: &str) -> Result<()> {
    if value == 0 {
        return Err(SlimgBridgeError::invalid_request(message));
    }
    Ok(())
}

fn read_existing_input_path(value: &str) -> Result<PathBuf> {
    let path = to_path_buf(value, "input_path")?;
    if !path.exists() {
        return Err(SlimgBridgeError::invalid_path(
            &path,
            "input file does not exist",
        ));
    }
    if !path.is_file() {
        return Err(SlimgBridgeError::invalid_path(
            &path,
            "input path is not a file",
        ));
    }
    Ok(path)
}

fn map_input_io(path: &Path, error: std::io::Error) -> SlimgBridgeError {
    if error.kind() == std::io::ErrorKind::NotFound {
        SlimgBridgeError::invalid_path(path, "input file does not exist")
    } else {
        error.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ProcessBytesRequest, ResizeOptions, ResizeSpec};
    use slimg_core::{ImageData, PipelineOptions};

    fn test_png_bytes() -> Vec<u8> {
        let image = test_image();
        slimg_core::convert(
            &image,
            &PipelineOptions {
                format: Format::Png,
                quality: 80,
                effort: None,
                png_palette: Default::default(),
                threads: None,
                resize: None,
                crop: None,
                extend: None,
                fill_color: None,
            },
        )
        .unwrap()
        .data
    }

    fn test_image() -> ImageData {
        let (width, height) = (32, 24);
        let mut data = vec![0_u8; (width * height * 4) as usize];
        for y in 0..height {
            for x in 0..width {
                let index = ((y * width + x) * 4) as usize;
                data[index] = (x * 255 / width) as u8;
                data[index + 1] = (y * 255 / height) as u8;
                data[index + 2] = 128;
                data[index + 3] = 255;
            }
        }
        ImageData::new(width, height, data)
    }

    #[test]
    fn inspect_bytes_returns_dimensions() {
        let metadata = inspect_bytes(test_png_bytes()).unwrap();
        assert_eq!(metadata.width, 32);
        assert_eq!(metadata.height, 24);
        assert_eq!(metadata.format, "png");
        assert_eq!(metadata.file_size, None);
        assert!(!metadata.has_transparency);
    }

    #[test]
    fn process_bytes_converts_to_webp() {
        let result = process_bytes(ProcessBytesRequest {
            color_profile_mode: ColorProfileMode::Preserve,
            data: test_png_bytes(),
            operation: ImageOperation::Convert(ConvertOptions {
                target_format: "webp".to_string(),
                quality: 80,
                effort: None,
                png_palette: None,
            }),
        })
        .unwrap();

        assert_eq!(result.format, "webp");
        assert!(!result.encoded_bytes.is_empty());
    }

    #[test]
    fn process_bytes_converts_to_avif() {
        let result = process_bytes(ProcessBytesRequest {
            color_profile_mode: ColorProfileMode::Preserve,
            data: test_png_bytes(),
            operation: ImageOperation::Convert(ConvertOptions {
                target_format: "avif".to_string(),
                quality: 80,
                effort: None,
                png_palette: None,
            }),
        })
        .unwrap();

        assert_eq!(result.format, "avif");
        assert_eq!(&result.encoded_bytes[4..8], b"ftyp");
    }

    #[test]
    fn avif_preview_includes_decoded_rgba() {
        let image = test_image();
        let output = run_preview_operation(
            &image,
            SourceFormat::Core(Format::Png),
            &ImageOperation::Convert(ConvertOptions {
                target_format: "avif".to_string(),
                quality: 80,
                effort: None,
                png_palette: None,
            }),
            None,
        )
        .unwrap();

        assert_eq!(output.format, Format::Avif);
        assert_eq!(&output.data[4..8], b"ftyp");
        assert_eq!(
            output.preview_rgba_bytes.len(),
            (output.width * output.height * 4) as usize
        );
    }

    #[test]
    fn avif_preview_accepts_zero_quality() {
        let image = test_image();
        let output = run_preview_operation(
            &image,
            SourceFormat::Core(Format::Png),
            &ImageOperation::Convert(ConvertOptions {
                target_format: "avif".to_string(),
                quality: 0,
                effort: None,
                png_palette: None,
            }),
            None,
        )
        .unwrap();

        assert_eq!(output.format, Format::Avif);
        assert_eq!(&output.data[4..8], b"ftyp");
        assert_eq!(
            output.preview_rgba_bytes.len(),
            (output.width * output.height * 4) as usize
        );
    }

    #[test]
    fn avif_uses_default_thread_budget_when_unspecified() {
        let threads = encode_threads_for_format(Format::Avif, None).unwrap();

        assert!((1..=4).contains(&threads));
        assert_eq!(encode_threads_for_format(Format::Avif, Some(2)), Some(2));
        assert_eq!(encode_threads_for_format(Format::Png, None), None);
    }

    #[test]
    fn process_bytes_rejects_invalid_scale() {
        let error = process_bytes(ProcessBytesRequest {
            color_profile_mode: ColorProfileMode::Preserve,
            data: test_png_bytes(),
            operation: ImageOperation::Resize(ResizeOptions {
                resize: ResizeSpec::Scale { factor: 0.0 },
                target_format: None,
                quality: 80,
                effort: None,
                png_palette: None,
            }),
        })
        .unwrap_err();

        assert!(matches!(error, SlimgBridgeError::InvalidRequest { .. }));
    }
}
