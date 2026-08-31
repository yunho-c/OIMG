use std::fs::{self, File};
use std::io::{BufRead, BufReader, Cursor, Seek};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use img_parts::{DynImage, ImageEXIF, ImageICC};
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
use crate::source_image::{
    decode_source_image, detect_source_format as detect_source_format_from_reader, map_probe_error,
    SourceFormat,
};
use crate::types::{
    BatchItemResult, BatchProcessRequest, ConvertOptions, CropSpec, EncodedImageResult, ExtendSpec,
    FillSpec, ImageMetadata, ImageOperation, OptimizeOptions, PreviewResult, ProcessBytesRequest,
    ProcessFileBatchRequest, ProcessFileRequest, ProcessResult, ResizeSpec,
};

pub(crate) fn inspect_file(input_path: String) -> Result<ImageMetadata> {
    let path = read_existing_input_path(&input_path)?;
    let file = File::open(&path).map_err(|error| map_input_io(&path, error))?;
    let file_size = file.metadata()?.len();
    inspect_reader(&mut BufReader::new(file), Some(file_size))
}

pub(crate) fn inspect_bytes(data: Vec<u8>) -> Result<ImageMetadata> {
    if data.is_empty() {
        return Err(SlimgBridgeError::invalid_request("data must not be empty"));
    }

    inspect_reader(&mut Cursor::new(data), None)
}

fn inspect_reader<R: BufRead + Seek>(
    reader: &mut R,
    file_size: Option<u64>,
) -> Result<ImageMetadata> {
    let (format, image_type) = detect_source_format_from_reader(reader)?;
    let dimensions = image_type.reader_size(reader).map_err(map_probe_error)?;
    let width = u32::try_from(dimensions.width)
        .map_err(|_| SlimgBridgeError::invalid_request("image width is too large"))?;
    let height = u32::try_from(dimensions.height)
        .map_err(|_| SlimgBridgeError::invalid_request("image height is too large"))?;
    if width == 0 || height == 0 {
        return Err(SlimgBridgeError::invalid_request(
            "image dimensions must be greater than zero",
        ));
    }

    Ok(ImageMetadata {
        width,
        height,
        format: format.id().to_string(),
        file_size,
        has_transparency: None,
    })
}

pub(crate) fn process_bytes(request: ProcessBytesRequest) -> Result<EncodedImageResult> {
    if request.data.is_empty() {
        return Err(SlimgBridgeError::invalid_request("data must not be empty"));
    }

    let output = run_operation(&request.data, &request.operation, None)?;
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
        let source = decode_source_image(&data)?;
        let palette_stats = should_analyze_palette_for_preview(&request.operation, source.format)?
            .then(|| analyze_palette_suitability(&source.image));
        let source_has_transparency = palette_stats.as_ref().map_or_else(
            || {
                source
                    .image
                    .data
                    .chunks_exact(4)
                    .any(|pixel| pixel[3] < 255)
            },
            |stats| stats.has_alpha,
        );
        let output = run_preview_operation(&source.image, source.format, &request.operation, None)?;
        let operation_elapsed = operation_start.elapsed();
        crate::diagnostics::timing_log(format!(
            "preview path={} read={}ms operation={}ms input_bytes={}",
            request.input_path,
            read_elapsed.as_millis(),
            operation_elapsed.as_millis(),
            data.len()
        ));

        Ok(PreviewResult {
            encoded_bytes: output.data.clone(),
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
            size_bytes: output.data.len() as u64,
            source_has_transparency,
            palette_suitability: palette_stats.map(Into::into),
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
        request.preserve_color_profile,
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
        false,
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
    preserve_color_profile: bool,
    operation: ImageOperation,
    threads: Option<usize>,
) -> Result<ProcessResult> {
    let total_start = Instant::now();
    let input = read_existing_input_path(&input_path)?;
    let input_bytes = fs::read(&input).map_err(|error| map_input_io(&input, error))?;
    let source_format = detect_source_format(&input_bytes)?;
    let target_format = resolve_output_format(&operation, source_format)?;
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

    let mut output = run_operation(&input_bytes, &operation, threads)?;
    let preserved_dates = if preserve_file_dates && output.should_write {
        crate::fs::PreservedFileDates::capture(&input)
    } else {
        None
    };
    if output.should_write {
        output.data = preserve_metadata(
            &input_bytes,
            output.data,
            preserve_exif,
            preserve_color_profile,
        )?;
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
        new_size: if output.should_write {
            output.data.len() as u64
        } else {
            input_bytes.len() as u64
        },
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

fn preserve_metadata(
    input_bytes: &[u8],
    output_bytes: Vec<u8>,
    preserve_exif: bool,
    preserve_color_profile: bool,
) -> Result<Vec<u8>> {
    if !preserve_exif && !preserve_color_profile {
        return Ok(output_bytes);
    }

    let Ok(Some(source_image)) = DynImage::from_bytes(input_bytes.to_vec().into()) else {
        return Ok(output_bytes);
    };

    let Some(mut output_image) =
        DynImage::from_bytes(output_bytes.clone().into()).map_err(|error| {
            SlimgBridgeError::Internal {
                message: format!("metadata output parse failed: {error}"),
            }
        })?
    else {
        return Ok(output_bytes);
    };

    if preserve_exif {
        output_image.set_exif(source_image.exif());
    }
    if preserve_color_profile {
        output_image.set_icc_profile(source_image.icc_profile());
    }

    let mut encoded = Vec::new();
    output_image
        .encoder()
        .write_to(&mut encoded)
        .map_err(|error| SlimgBridgeError::Internal {
            message: format!("metadata encode failed: {error}"),
        })?;
    Ok(encoded)
}

fn run_operation(
    data: &[u8],
    operation: &ImageOperation,
    threads: Option<usize>,
) -> Result<OperationOutput> {
    match operation {
        ImageOperation::Convert(options) => convert_bytes(data, options, threads),
        ImageOperation::Optimize(options) => optimize_bytes(data, options, threads),
        ImageOperation::Resize(options) => transform_bytes(data, options.quality, |source| {
            Ok(PipelineOptions {
                format: resolve_optional_target_format(options.target_format.as_deref(), source)?,
                quality: validate_quality(options.quality)?,
                effort: validate_effort(options.effort)?,
                png_palette: map_png_palette(options.png_palette),
                threads,
                resize: Some(map_resize_spec(&options.resize)?),
                crop: None,
                extend: None,
                fill_color: None,
            })
        }),
        ImageOperation::Crop(options) => transform_bytes(data, options.quality, |source| {
            Ok(PipelineOptions {
                format: resolve_optional_target_format(options.target_format.as_deref(), source)?,
                quality: validate_quality(options.quality)?,
                effort: validate_effort(options.effort)?,
                png_palette: map_png_palette(options.png_palette),
                threads,
                resize: None,
                crop: Some(map_crop_spec(&options.crop)?),
                extend: None,
                fill_color: None,
            })
        }),
        ImageOperation::Extend(options) => transform_bytes(data, options.quality, |source| {
            Ok(PipelineOptions {
                format: resolve_optional_target_format(options.target_format.as_deref(), source)?,
                quality: validate_quality(options.quality)?,
                effort: validate_effort(options.effort)?,
                png_palette: map_png_palette(options.png_palette),
                threads,
                resize: None,
                crop: None,
                extend: Some(map_extend_spec(&options.extend)?),
                fill_color: map_fill_spec(options.fill.as_ref()),
            })
        }),
    }
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
) -> Result<OperationOutput> {
    let quality = validate_quality(options.quality)?;
    let effort = validate_effort(options.effort)?;
    let target_format = crate::codec::parse_format(&options.target_format)?;
    let source = decode_source_image(data)?;
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
) -> Result<OperationOutput> {
    let quality = validate_quality(options.quality)?;
    let effort = validate_effort(options.effort)?;
    let total_start = Instant::now();

    let decode_start = Instant::now();
    let source = decode_source_image(data)?;
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

fn transform_bytes<F>(data: &[u8], quality: u8, build: F) -> Result<OperationOutput>
where
    F: FnOnce(SourceFormat) -> Result<PipelineOptions>,
{
    let source = decode_source_image(data)?;
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
    Ok(detect_source_format_from_reader(&mut Cursor::new(data))?.0)
}

fn should_analyze_palette_for_preview(
    operation: &ImageOperation,
    source_format: SourceFormat,
) -> Result<bool> {
    if resolve_output_format(operation, source_format)? != Format::Png {
        return Ok(false);
    }

    let palette_mode = match operation {
        ImageOperation::Convert(options) => options.png_palette,
        ImageOperation::Optimize(options) => options.png_palette,
        ImageOperation::Resize(options) => options.png_palette,
        ImageOperation::Crop(options) => options.png_palette,
        ImageOperation::Extend(options) => options.png_palette,
    };
    Ok(map_png_palette(palette_mode) == CorePngPaletteMode::Off)
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
    use crate::types::{PngPaletteMode, ProcessBytesRequest, ResizeOptions, ResizeSpec};
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
        assert_eq!(metadata.has_transparency, None);
    }

    #[test]
    fn inspect_bytes_only_requires_the_image_header() {
        let bytes = test_png_bytes();
        let metadata = inspect_bytes(bytes[..24].to_vec()).unwrap();

        assert_eq!((metadata.width, metadata.height), (32, 24));
        assert_eq!(metadata.format, "png");
    }

    #[test]
    fn palette_advice_is_only_computed_for_png_with_palette_disabled() {
        let source_format = SourceFormat::Core(Format::Png);
        let png_off = ImageOperation::Optimize(OptimizeOptions {
            quality: 100,
            effort: None,
            png_palette: Some(PngPaletteMode::Off),
            write_only_if_smaller: true,
        });
        let png_auto = ImageOperation::Optimize(OptimizeOptions {
            quality: 100,
            effort: None,
            png_palette: Some(PngPaletteMode::Auto),
            write_only_if_smaller: true,
        });
        let jpeg = ImageOperation::Convert(ConvertOptions {
            target_format: "jpeg".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        });

        assert!(should_analyze_palette_for_preview(&png_off, source_format).unwrap());
        assert!(!should_analyze_palette_for_preview(&png_auto, source_format).unwrap());
        assert!(!should_analyze_palette_for_preview(&jpeg, source_format).unwrap());
    }

    #[test]
    fn process_bytes_converts_to_webp() {
        let result = process_bytes(ProcessBytesRequest {
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
