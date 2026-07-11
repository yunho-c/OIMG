use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use slimg_core::{codec::get_codec, EncodeOptions, Format, ImageData};

use crate::codec::parse_format;
use crate::error::{panic_message, Result, SlimgBridgeError};
use crate::fs::safe_write_bytes;
use crate::source_image::decode_source_image;
use crate::types::{
    BatchItemResult, ConvertOptions, ImageOperation, OptimizeOptions, PngPaletteMode,
    ProcessFileBatchRequest, ProcessFileRequest, ProcessResult,
};

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum CompressionAction {
    Compress,
    CompressKeepOriginal,
    SaveAsPng,
    SaveAsJpg,
}

#[derive(Debug, Deserialize)]
struct CompressionServiceRequest {
    action: CompressionAction,
    paths: Vec<String>,
    settings: CompressionServiceSettings,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompressionServiceSettings {
    compression_method: CompressionMethod,
    compression_priority: CompressionPriority,
    advanced_mode: bool,
    preferred_codec: PreferredCodec,
    quality: u8,
    effort: Option<u8>,
    png_palette_mode: Option<PngPaletteMode>,
}

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum CompressionMethod {
    Lossless,
    Lossy,
}

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum CompressionPriority {
    Compatibility,
    Efficiency,
}

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum PreferredCodec {
    Png,
    Jpeg,
    Webp,
    Avif,
    Jxl,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
struct CompressionServiceResponse {
    success_count: usize,
    failure_count: usize,
    items: Vec<CompressionServiceItem>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
struct CompressionServiceItem {
    input_path: String,
    output_path: Option<String>,
    error: Option<String>,
}

#[no_mangle]
pub extern "C" fn oimg_service_run_request(request_json: *const c_char) -> *mut c_char {
    match CString::new(run_request_json_from_ptr(request_json)) {
        Ok(value) => value.into_raw(),
        Err(_) => CString::new(
            r#"{"success_count":0,"failure_count":1,"items":[{"input_path":"","output_path":null,"error":"internal error: failed to serialize service response"}]}"#,
        )
        .expect("valid fallback JSON")
        .into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn oimg_service_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(value));
    }
}

pub fn run_request_json(request_json: &str) -> String {
    let response =
        catch_unwind(AssertUnwindSafe(|| run_request(request_json))).unwrap_or_else(|payload| {
            CompressionServiceResponse {
                success_count: 0,
                failure_count: 1,
                items: vec![CompressionServiceItem {
                    input_path: String::new(),
                    output_path: None,
                    error: Some(format!("internal error: {}", panic_message(payload))),
                }],
            }
        });

    serde_json::to_string(&response).unwrap_or_else(|_| {
        r#"{"success_count":0,"failure_count":1,"items":[{"input_path":"","output_path":null,"error":"internal error: failed to serialize service response"}]}"#
            .to_string()
    })
}

fn run_request_json_from_ptr(request_json: *const c_char) -> String {
    if request_json.is_null() {
        return serde_json::to_string(&invalid_response("request JSON must not be null"))
            .expect("valid service response");
    }

    let request_json = match unsafe { CStr::from_ptr(request_json) }.to_str() {
        Ok(value) => value,
        Err(_) => {
            return serde_json::to_string(&invalid_response("request JSON must be valid UTF-8"))
                .expect("valid service response");
        }
    };

    run_request_json(request_json)
}

fn run_request(request_json: &str) -> CompressionServiceResponse {
    let request = match serde_json::from_str::<CompressionServiceRequest>(request_json) {
        Ok(value) => value,
        Err(error) => {
            return invalid_response(format!("invalid request JSON: {error}"));
        }
    };

    if request.paths.is_empty() {
        return invalid_response("paths must contain at least one file");
    }

    match process_request(request) {
        Ok(results) => {
            let mut success_count = 0;
            let mut failure_count = 0;
            let mut items = Vec::with_capacity(results.len());

            for item in results {
                if item.success {
                    success_count += 1;
                } else {
                    failure_count += 1;
                }

                items.push(CompressionServiceItem {
                    input_path: item.input_path,
                    output_path: item.result.map(|result| result.output_path),
                    error: item.error.map(|error| error.to_string()),
                });
            }

            CompressionServiceResponse {
                success_count,
                failure_count,
                items,
            }
        }
        Err(error) => invalid_response(error.to_string()),
    }
}

fn process_request(request: CompressionServiceRequest) -> Result<Vec<BatchItemResult>> {
    match request.action {
        CompressionAction::Compress | CompressionAction::CompressKeepOriginal => {
            let batch_request = build_batch_request(request)?;
            crate::convert::process_file_batch(batch_request)
        }
        CompressionAction::SaveAsPng | CompressionAction::SaveAsJpg => process_save_as(request),
    }
}

fn build_batch_request(request: CompressionServiceRequest) -> Result<ProcessFileBatchRequest> {
    let CompressionServiceRequest {
        action,
        paths,
        settings,
    } = request;
    let target_codec = settings.effective_codec();
    let mut requests = Vec::with_capacity(paths.len());

    for input_path in paths {
        let metadata = crate::convert::inspect_file(input_path.clone())?;
        let source_format = metadata.format;
        let same_format = source_format == target_codec;
        let output_path = if same_format {
            None
        } else {
            Some(
                sibling_optimized_path(&input_path, &target_codec)
                    .to_string_lossy()
                    .into_owned(),
            )
        };

        let overwrite = if same_format {
            matches!(action, CompressionAction::Compress)
        } else {
            true
        };

        let operation = if same_format {
            ImageOperation::Optimize(OptimizeOptions {
                quality: settings.quality,
                effort: settings.effort,
                png_palette: settings.png_palette_mode,
                write_only_if_smaller: true,
            })
        } else {
            ImageOperation::Convert(ConvertOptions {
                target_format: target_codec.clone(),
                quality: settings.quality,
                effort: settings.effort,
                png_palette: settings.png_palette_mode,
            })
        };

        requests.push(ProcessFileRequest {
            input_path,
            output_path,
            overwrite,
            preserve_file_dates: false,
            preserve_exif: false,
            color_profile_mode: crate::types::ColorProfileMode::Preserve,
            operation,
        });
    }

    Ok(ProcessFileBatchRequest {
        requests,
        continue_on_error: true,
    })
}

fn process_save_as(request: CompressionServiceRequest) -> Result<Vec<BatchItemResult>> {
    let CompressionServiceRequest {
        action,
        paths,
        settings,
    } = request;
    let mut results = Vec::with_capacity(paths.len());

    for input_path in paths {
        let result = process_save_as_path(&input_path, action, &settings);
        match result {
            Ok(result) => results.push(BatchItemResult {
                input_path,
                success: true,
                result: Some(result),
                error: None,
            }),
            Err(error) => results.push(BatchItemResult {
                input_path,
                success: false,
                result: None,
                error: Some(error),
            }),
        }
    }

    Ok(results)
}

fn process_save_as_path(
    input_path: &str,
    action: CompressionAction,
    settings: &CompressionServiceSettings,
) -> Result<ProcessResult> {
    let target_format = action
        .save_as_target_format()
        .ok_or_else(|| SlimgBridgeError::invalid_request("unsupported save action"))?;
    let output_path = save_as_output_path(input_path, target_format);

    match action {
        CompressionAction::SaveAsPng => crate::convert::process_file_request_with_threads(
            ProcessFileRequest {
                input_path: input_path.to_string(),
                output_path: Some(output_path.to_string_lossy().into_owned()),
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                color_profile_mode: crate::types::ColorProfileMode::Preserve,
                operation: ImageOperation::Convert(ConvertOptions {
                    target_format: target_format.to_string(),
                    quality: 80,
                    effort: None,
                    png_palette: None,
                }),
            },
            None,
        ),
        CompressionAction::SaveAsJpg => process_save_as_jpg(input_path, &output_path, settings),
        CompressionAction::Compress | CompressionAction::CompressKeepOriginal => {
            Err(SlimgBridgeError::invalid_request("unsupported save action"))
        }
    }
}

fn process_save_as_jpg(
    input_path: &str,
    output_path: &Path,
    settings: &CompressionServiceSettings,
) -> Result<ProcessResult> {
    let input_path_buf = PathBuf::from(input_path);
    if !input_path_buf.exists() {
        return Err(SlimgBridgeError::invalid_path(
            &input_path_buf,
            "input file does not exist",
        ));
    }
    if !input_path_buf.is_file() {
        return Err(SlimgBridgeError::invalid_path(
            &input_path_buf,
            "input path is not a file",
        ));
    }

    let input_bytes = fs::read(&input_path_buf)?;
    let source = decode_source_image(&input_bytes)?;
    let flattened = composite_image_onto_white(&source.image);
    let encoded = get_codec(Format::Jpeg).encode(
        &flattened,
        &EncodeOptions {
            quality: settings.quality,
            effort: settings.effort,
            png_palette: Default::default(),
            threads: None,
        },
    )?;

    safe_write_bytes(output_path, &encoded, true, None)?;

    Ok(ProcessResult {
        output_path: output_path.to_string_lossy().into_owned(),
        format: "jpeg".to_string(),
        width: flattened.width,
        height: flattened.height,
        original_size: input_bytes.len() as u64,
        new_size: encoded.len() as u64,
        did_write: true,
    })
}

fn composite_image_onto_white(image: &ImageData) -> ImageData {
    let data = image
        .data
        .chunks_exact(4)
        .flat_map(|pixel| {
            let [r, g, b, a]: [u8; 4] = pixel.try_into().expect("pixel chunk should be RGBA");
            let alpha = u32::from(a);
            let inv_alpha = 255 - alpha;
            [
                ((u32::from(r) * alpha + 255 * inv_alpha) / 255) as u8,
                ((u32::from(g) * alpha + 255 * inv_alpha) / 255) as u8,
                ((u32::from(b) * alpha + 255 * inv_alpha) / 255) as u8,
                255,
            ]
        })
        .collect();
    ImageData::new(image.width, image.height, data)
}

fn sibling_optimized_path(input_path: &str, target_format: &str) -> PathBuf {
    let input = Path::new(input_path);
    let stem = input
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("output");
    let extension = parse_format(target_format)
        .expect("service uses supported target formats")
        .extension();
    input.with_file_name(format!("{stem}.optimized.{extension}"))
}

fn save_as_output_path(input_path: &str, target_format: &str) -> PathBuf {
    let input = Path::new(input_path);
    let stem = input
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("output");
    let extension = parse_format(target_format)
        .expect("service uses supported target formats")
        .extension();
    input.with_file_name(format!("{stem}.{extension}"))
}

fn invalid_response(message: impl Into<String>) -> CompressionServiceResponse {
    CompressionServiceResponse {
        success_count: 0,
        failure_count: 1,
        items: vec![CompressionServiceItem {
            input_path: String::new(),
            output_path: None,
            error: Some(message.into()),
        }],
    }
}

impl CompressionServiceSettings {
    fn effective_codec(&self) -> String {
        if self.advanced_mode {
            return self.preferred_codec.id().to_string();
        }

        match (&self.compression_method, &self.compression_priority) {
            (CompressionMethod::Lossless, CompressionPriority::Compatibility) => "png",
            (CompressionMethod::Lossless, CompressionPriority::Efficiency) => "jxl",
            (CompressionMethod::Lossy, CompressionPriority::Compatibility) => "jpeg",
            (CompressionMethod::Lossy, CompressionPriority::Efficiency) => "avif",
        }
        .to_string()
    }
}

impl PreferredCodec {
    fn id(&self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
            Self::Webp => "webp",
            Self::Avif => "avif",
            Self::Jxl => "jxl",
        }
    }
}

impl CompressionAction {
    fn save_as_target_format(self) -> Option<&'static str> {
        match self {
            Self::SaveAsPng => Some("png"),
            Self::SaveAsJpg => Some("jpeg"),
            Self::Compress | Self::CompressKeepOriginal => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use slimg_core::{convert, decode, Format, ImageData, PipelineOptions};
    use tempfile::tempdir;

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

    fn png_bytes() -> Vec<u8> {
        convert(
            &test_image(),
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

    fn transparent_png_bytes() -> Vec<u8> {
        let image = ImageData::new(1, 1, vec![0, 0, 0, 0]);
        convert(
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

    fn run_service_request(request: serde_json::Value) -> CompressionServiceResponse {
        let request = CString::new(request.to_string()).unwrap();
        let response = oimg_service_run_request(request.as_ptr());
        let response_json = unsafe { CStr::from_ptr(response) }
            .to_str()
            .unwrap()
            .to_string();
        oimg_service_free_string(response);
        serde_json::from_str(&response_json).unwrap()
    }

    #[test]
    fn compress_keep_original_returns_successful_result() {
        let dir = tempdir().unwrap();
        let input_path = dir.path().join("sample.png");
        fs::write(&input_path, png_bytes()).unwrap();

        let request = serde_json::json!({
            "action": "compress_keep_original",
            "paths": [input_path.to_string_lossy()],
            "settings": {
                "compressionMethod": "lossless",
                "compressionPriority": "compatibility",
                "advancedMode": true,
                "preferredCodec": "png",
                "quality": 80
            }
        });
        let response = run_service_request(request);
        assert_eq!(response.success_count, 1);
        assert_eq!(response.failure_count, 0);
        let output_path = response.items[0].output_path.as_ref().unwrap();
        assert!(
            output_path.ends_with("sample.optimized.png") || output_path.ends_with("sample.png")
        );
    }

    #[test]
    fn compress_uses_sibling_output_when_codec_changes() {
        let dir = tempdir().unwrap();
        let input_path = dir.path().join("sample.png");
        fs::write(&input_path, png_bytes()).unwrap();

        let request = serde_json::json!({
            "action": "compress",
            "paths": [input_path.to_string_lossy()],
            "settings": {
                "compressionMethod": "lossy",
                "compressionPriority": "compatibility",
                "advancedMode": false,
                "preferredCodec": "png",
                "quality": 80
            }
        });
        let response = run_service_request(request);
        assert_eq!(response.success_count, 1);
        assert_eq!(response.failure_count, 0);
        let output_path = response.items[0].output_path.as_ref().unwrap();
        assert!(output_path.ends_with("sample.optimized.jpg"));
        assert!(input_path.exists());
    }

    #[test]
    fn save_as_png_writes_sibling_png_output() {
        let dir = tempdir().unwrap();
        let input_path = dir.path().join("sample.webp");
        let output_path = dir.path().join("sample.png");
        let webp_bytes = convert(
            &test_image(),
            &PipelineOptions {
                format: Format::WebP,
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
        .data;
        fs::write(&input_path, webp_bytes).unwrap();

        let response = run_service_request(serde_json::json!({
            "action": "save_as_png",
            "paths": [input_path.to_string_lossy()],
            "settings": {
                "compressionMethod": "lossy",
                "compressionPriority": "compatibility",
                "advancedMode": false,
                "preferredCodec": "jpeg",
                "quality": 12
            }
        }));

        assert_eq!(response.success_count, 1);
        assert_eq!(response.failure_count, 0);
        assert_eq!(
            response.items[0].output_path.as_deref(),
            Some(output_path.to_string_lossy().as_ref())
        );
        assert!(output_path.exists());
        let output_bytes = fs::read(&output_path).unwrap();
        let (_, format) = decode(&output_bytes).unwrap();
        assert_eq!(format, Format::Png);
    }

    #[test]
    fn save_as_jpg_overwrites_existing_target_and_flattens_transparency_to_white() {
        let dir = tempdir().unwrap();
        let input_path = dir.path().join("transparent.png");
        let output_path = dir.path().join("transparent.jpg");
        fs::write(&input_path, transparent_png_bytes()).unwrap();
        fs::write(&output_path, b"old-jpeg").unwrap();

        let response = run_service_request(serde_json::json!({
            "action": "save_as_jpg",
            "paths": [input_path.to_string_lossy()],
            "settings": {
                "compressionMethod": "lossy",
                "compressionPriority": "compatibility",
                "advancedMode": false,
                "preferredCodec": "jpeg",
                "quality": 80
            }
        }));

        assert_eq!(response.success_count, 1);
        assert_eq!(response.failure_count, 0);
        assert_eq!(
            response.items[0].output_path.as_deref(),
            Some(output_path.to_string_lossy().as_ref())
        );

        let output_bytes = fs::read(&output_path).unwrap();
        assert_ne!(output_bytes, b"old-jpeg");
        let (decoded, format) = decode(&output_bytes).unwrap();
        assert_eq!(format, Format::Jpeg);
        assert!(decoded.data[0] > 240);
        assert!(decoded.data[1] > 240);
        assert!(decoded.data[2] > 240);
        assert_eq!(decoded.data[3], 255);
    }

    #[test]
    fn invalid_json_returns_error_response() {
        let request = CString::new("{").unwrap();
        let response = oimg_service_run_request(request.as_ptr());
        let response_json = unsafe { CStr::from_ptr(response) }
            .to_str()
            .unwrap()
            .to_string();
        oimg_service_free_string(response);
        let response: CompressionServiceResponse = serde_json::from_str(&response_json).unwrap();
        assert_eq!(response.success_count, 0);
        assert_eq!(response.failure_count, 1);
        assert!(response.items[0].error.is_some());
    }
}
