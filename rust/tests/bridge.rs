use std::fs;
#[cfg(target_os = "macos")]
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use oimg_rust::api::bridge::{
    self, AnalyzeFileRequest, BatchJobState, BatchProcessRequest, ConvertOptions, CropOptions,
    CropSpec, ImageOperation, OptimizeOptions, PreviewArtifactRequest, PreviewFileRequest,
    ProcessBytesRequest, ProcessFileBatchRequest, ProcessFileRequest, ResizeOptions, ResizeSpec,
};
use slimg_core::{convert, decode, Format, ImageData, PipelineOptions};
use tempfile::tempdir;

fn test_image() -> ImageData {
    gradient_image(48, 32)
}

fn gradient_image(width: u32, height: u32) -> ImageData {
    let mut data = vec![0_u8; (width * height * 4) as usize];
    for y in 0..height {
        for x in 0..width {
            let index = ((y * width + x) * 4) as usize;
            data[index] = (x * 255 / width) as u8;
            data[index + 1] = (y * 255 / height) as u8;
            data[index + 2] = 96;
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

fn png_bytes_with_size(width: u32, height: u32) -> Vec<u8> {
    convert(
        &gradient_image(width, height),
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

fn wait_for_job(job_id: &str) -> oimg_rust::api::bridge::BatchJobSnapshot {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = bridge::get_process_file_batch_job(job_id.to_string()).unwrap();
        if matches!(
            snapshot.state,
            BatchJobState::Completed | BatchJobState::Canceled | BatchJobState::Failed
        ) {
            return snapshot;
        }

        assert!(Instant::now() < deadline, "timed out waiting for batch job");
        thread::sleep(Duration::from_millis(20));
    }
}

fn wait_for_analyze_job(job_id: &str) -> oimg_rust::api::bridge::AnalyzeFileJobSnapshot {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = bridge::get_analyze_file_job(job_id.to_string()).unwrap();
        if matches!(
            snapshot.state,
            BatchJobState::Completed | BatchJobState::Canceled | BatchJobState::Failed
        ) {
            return snapshot;
        }

        assert!(
            Instant::now() < deadline,
            "timed out waiting for analyze job"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn inspect_bytes_reports_png_dimensions() {
    let metadata = bridge::inspect_bytes(png_bytes()).unwrap();
    assert_eq!(metadata.width, 48);
    assert_eq!(metadata.height, 32);
    assert_eq!(metadata.format, "png");
    assert_eq!(metadata.file_size, None);
    assert_eq!(metadata.has_transparency, None);
}

#[cfg(target_os = "macos")]
#[test]
fn inspect_and_preview_file_decode_heic_with_imageio() {
    let dir = tempdir().unwrap();
    let png_path = dir.path().join("input.png");
    let heic_path = dir.path().join("input.heic");
    fs::write(&png_path, png_bytes()).unwrap();

    let status = Command::new("sips")
        .arg("-s")
        .arg("format")
        .arg("heic")
        .arg(&png_path)
        .arg("--out")
        .arg(&heic_path)
        .status();
    let Ok(status) = status else {
        eprintln!("skipping HEIC decode test because sips is unavailable");
        return;
    };
    if !status.success() {
        eprintln!("skipping HEIC decode test because sips cannot encode HEIC");
        return;
    }

    let metadata = bridge::inspect_file(heic_path.to_string_lossy().into_owned()).unwrap();
    assert_eq!(metadata.width, 48);
    assert_eq!(metadata.height, 32);
    assert_eq!(metadata.format, "heic");

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: heic_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "jpeg".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();
    assert_eq!(preview.format, "jpeg");
    assert_eq!(preview.width, 48);
    assert_eq!(preview.height, 32);

    let (decoded_preview, _) = decode(&preview.encoded_bytes).unwrap();
    let top_left_green = decoded_preview.data[1];
    let bottom_left_green = decoded_preview.data[((31 * 48) * 4 + 1) as usize];
    assert!(
        top_left_green < bottom_left_green,
        "HEIC decode should preserve vertical orientation"
    );
}

#[test]
fn process_bytes_converts_to_webp() {
    let result = bridge::process_bytes(ProcessBytesRequest {
        data: png_bytes(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "webp".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    assert_eq!(result.format, "webp");
    assert!(result.size_bytes > 0);
}

#[test]
fn preview_file_crops_without_writing() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Crop(CropOptions {
            crop: CropSpec::AspectRatio {
                width: 1,
                height: 1,
            },
            target_format: None,
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    let (decoded, format) = decode(&preview.encoded_bytes).unwrap();
    assert_eq!(format, Format::Png);
    assert_eq!(decoded.width, 32);
    assert_eq!(decoded.height, 32);
    assert!(!preview.source_has_transparency);
    assert!(preview.palette_suitability.is_some());
}

#[test]
fn preview_file_converts_to_avif_with_metrics() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "avif".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    assert_eq!(preview.format, "avif");
    assert_eq!(&preview.encoded_bytes[4..8], b"ftyp");
    assert!(!preview.source_has_transparency);
    assert!(preview.palette_suitability.is_none());
    let pixel_match = bridge::compute_preview_pixel_match_percentage(PreviewArtifactRequest {
        artifact_id: preview.artifact_id.clone(),
    })
    .unwrap()
    .expect("expected AVIF preview metric");
    assert!((0.0..=100.0).contains(&pixel_match));
    bridge::dispose_preview_artifact(preview.artifact_id).unwrap();
}

#[test]
fn preview_metric_rpcs_return_values_for_same_dimension_preview() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "jpeg".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    let request = PreviewArtifactRequest {
        artifact_id: preview.artifact_id.clone(),
    };

    let pixel_match = bridge::compute_preview_pixel_match_percentage(request.clone())
        .unwrap()
        .expect("expected pixel match metric");
    assert!(
        (0.0..=100.0).contains(&pixel_match),
        "expected Pixel Match in [0, 100], got {pixel_match}"
    );

    let metric = bridge::compute_preview_ms_ssim(request.clone())
        .unwrap()
        .expect("expected preview metric");
    assert!(
        (0.0..=1.0).contains(&metric),
        "expected metric in [0, 1], got {metric}"
    );

    let ssimulacra2 = bridge::compute_preview_ssimulacra2(request.clone())
        .unwrap()
        .expect("expected ssimulacra2 metric");
    assert!(
        (0.0..=100.0).contains(&ssimulacra2),
        "expected SSIMULACRA 2 in [0, 100], got {ssimulacra2}"
    );

    let diff = bridge::compute_preview_difference_image(request)
        .unwrap()
        .expect("expected difference preview");
    assert_eq!(diff.width, 48);
    assert_eq!(diff.height, 32);
    assert_eq!(diff.rgba_bytes.len(), 48 * 32 * 4);
    bridge::dispose_preview_artifact(preview.artifact_id).unwrap();
}

#[test]
fn preview_metric_rpcs_return_none_when_metric_cannot_be_computed() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Resize(ResizeOptions {
            resize: ResizeSpec::Width { value: 24 },
            target_format: None,
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    let request = PreviewArtifactRequest {
        artifact_id: preview.artifact_id.clone(),
    };

    assert_eq!(
        bridge::compute_preview_pixel_match_percentage(request.clone()).unwrap(),
        None
    );
    assert_eq!(
        bridge::compute_preview_ms_ssim(request.clone()).unwrap(),
        None
    );
    assert_eq!(
        bridge::compute_preview_ssimulacra2(request.clone()).unwrap(),
        None
    );
    assert_eq!(
        bridge::compute_preview_difference_image(request).unwrap(),
        None
    );
    bridge::dispose_preview_artifact(preview.artifact_id).unwrap();
}

#[test]
fn dispose_preview_artifact_invalidates_followup_requests() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let preview = bridge::preview_file(PreviewFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "jpeg".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    let request = PreviewArtifactRequest {
        artifact_id: preview.artifact_id.clone(),
    };
    bridge::dispose_preview_artifact(preview.artifact_id).unwrap();

    let error = bridge::compute_preview_ms_ssim(request).unwrap_err();
    assert!(
        error.to_string().contains("unknown preview artifact"),
        "unexpected error: {error}"
    );
}

#[test]
fn process_file_derives_suffixed_output_when_overwrite_is_false() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("photo.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let result = bridge::process_file(ProcessFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        output_path: None,
        overwrite: false,
        preserve_file_dates: false,
        preserve_exif: false,
        preserve_color_profile: false,
        operation: ImageOperation::Resize(ResizeOptions {
            resize: ResizeSpec::Width { value: 24 },
            target_format: None,
            quality: 80,
            effort: None,
            png_palette: None,
        }),
    })
    .unwrap();

    assert!(result.output_path.ends_with("photo.resized.png"));
    assert_eq!(result.width, 24);
    assert!(result.did_write);

    let written_bytes = fs::read(&result.output_path).unwrap();
    let (decoded, format) = decode(&written_bytes).unwrap();
    assert_eq!(format, Format::Png);
    assert_eq!(decoded.width, 24);
    assert_eq!(decoded.height, 16);
}

#[test]
fn process_file_reports_skipped_write_when_optimized_result_is_not_smaller() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("photo.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let result = bridge::process_file(ProcessFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        output_path: None,
        overwrite: true,
        preserve_file_dates: false,
        preserve_exif: false,
        preserve_color_profile: false,
        operation: ImageOperation::Optimize(OptimizeOptions {
            quality: 100,
            effort: None,
            png_palette: None,
            write_only_if_smaller: true,
        }),
    })
    .unwrap();

    assert_eq!(result.output_path, input_path.to_string_lossy());
    assert!(!result.did_write || result.new_size < result.original_size);
}

#[test]
fn process_files_returns_ordered_partial_failures() {
    let dir = tempdir().unwrap();
    let output_dir = dir.path().join("out");
    let first_path = dir.path().join("first.png");
    let third_path = dir.path().join("third.png");
    let missing_path = dir.path().join("missing.png");

    fs::write(&first_path, png_bytes()).unwrap();
    fs::write(&third_path, png_bytes()).unwrap();

    let results = bridge::process_files(BatchProcessRequest {
        input_paths: vec![
            first_path.to_string_lossy().into_owned(),
            missing_path.to_string_lossy().into_owned(),
            third_path.to_string_lossy().into_owned(),
        ],
        output_dir: Some(output_dir.to_string_lossy().into_owned()),
        overwrite: false,
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "webp".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
        continue_on_error: true,
    })
    .unwrap();

    assert_eq!(results.len(), 3);
    assert!(results[0].success);
    assert!(!results[1].success);
    assert!(results[2].success);
    assert_eq!(results[0].input_path, first_path.to_string_lossy());
    assert_eq!(results[1].input_path, missing_path.to_string_lossy());
    assert_eq!(results[2].input_path, third_path.to_string_lossy());
}

#[test]
fn process_file_batch_supports_mixed_operations() {
    let dir = tempdir().unwrap();
    let first_path = dir.path().join("first.png");
    let second_path = dir.path().join("second.png");
    let second_output = dir.path().join("second.optimized.jpg");

    fs::write(&first_path, png_bytes()).unwrap();
    fs::write(&second_path, png_bytes()).unwrap();

    let results = bridge::process_file_batch(ProcessFileBatchRequest {
        requests: vec![
            ProcessFileRequest {
                input_path: first_path.to_string_lossy().into_owned(),
                output_path: None,
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                preserve_color_profile: false,
                operation: ImageOperation::Optimize(OptimizeOptions {
                    quality: 80,
                    effort: None,
                    png_palette: None,
                    write_only_if_smaller: true,
                }),
            },
            ProcessFileRequest {
                input_path: second_path.to_string_lossy().into_owned(),
                output_path: Some(second_output.to_string_lossy().into_owned()),
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                preserve_color_profile: false,
                operation: ImageOperation::Convert(ConvertOptions {
                    target_format: "jpeg".to_string(),
                    quality: 80,
                    effort: None,
                    png_palette: None,
                }),
            },
        ],
        continue_on_error: true,
    })
    .unwrap();

    assert_eq!(results.len(), 2);
    assert!(results[0].success);
    assert!(results[1].success);
    assert_eq!(
        results[1].result.as_ref().unwrap().output_path,
        second_output.to_string_lossy()
    );
    assert!(results[1].result.as_ref().unwrap().did_write);
}

#[test]
fn process_file_batch_job_reports_progress_and_can_be_disposed() {
    let dir = tempdir().unwrap();
    let first_path = dir.path().join("first.png");
    let second_path = dir.path().join("second.png");
    let first_output = dir.path().join("first.optimized.jpeg");
    let second_output = dir.path().join("second.optimized.jpeg");

    fs::write(&first_path, png_bytes()).unwrap();
    fs::write(&second_path, png_bytes()).unwrap();

    let handle = bridge::start_process_file_batch_job(ProcessFileBatchRequest {
        requests: vec![
            ProcessFileRequest {
                input_path: first_path.to_string_lossy().into_owned(),
                output_path: Some(first_output.to_string_lossy().into_owned()),
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                preserve_color_profile: false,
                operation: ImageOperation::Convert(ConvertOptions {
                    target_format: "jpeg".to_string(),
                    quality: 80,
                    effort: None,
                    png_palette: None,
                }),
            },
            ProcessFileRequest {
                input_path: second_path.to_string_lossy().into_owned(),
                output_path: Some(second_output.to_string_lossy().into_owned()),
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                preserve_color_profile: false,
                operation: ImageOperation::Convert(ConvertOptions {
                    target_format: "jpeg".to_string(),
                    quality: 80,
                    effort: None,
                    png_palette: None,
                }),
            },
        ],
        continue_on_error: true,
    })
    .unwrap();

    let initial = bridge::get_process_file_batch_job(handle.job_id.clone()).unwrap();
    assert_eq!(initial.total_count, 2);
    assert!(initial.completed_count <= 2);

    let snapshot = wait_for_job(&handle.job_id);
    assert_eq!(snapshot.state, BatchJobState::Completed);
    assert_eq!(snapshot.completed_count, 2);
    assert_eq!(snapshot.results.len(), 2);
    let mut input_paths: Vec<_> = snapshot
        .results
        .iter()
        .map(|result| result.input_path.clone())
        .collect();
    input_paths.sort();
    assert_eq!(
        input_paths,
        vec![
            first_path.to_string_lossy().into_owned(),
            second_path.to_string_lossy().into_owned(),
        ]
    );

    bridge::dispose_process_file_batch_job(handle.job_id.clone()).unwrap();
    let error = bridge::get_process_file_batch_job(handle.job_id).unwrap_err();
    assert!(error.to_string().contains("unknown batch job"));
}

#[test]
fn cancel_process_file_batch_job_stops_remaining_files() {
    let dir = tempdir().unwrap();
    let mut requests = Vec::new();

    for index in 0..100 {
        let input_path = dir.path().join(format!("input-{index}.png"));
        let output_path = dir.path().join(format!("output-{index}.jpeg"));
        fs::write(&input_path, png_bytes_with_size(48, 32)).unwrap();
        requests.push(ProcessFileRequest {
            input_path: input_path.to_string_lossy().into_owned(),
            output_path: Some(output_path.to_string_lossy().into_owned()),
            overwrite: true,
            preserve_file_dates: false,
            preserve_exif: false,
            preserve_color_profile: false,
            operation: ImageOperation::Convert(ConvertOptions {
                target_format: "jpeg".to_string(),
                quality: 90,
                effort: None,
                png_palette: None,
            }),
        });
    }

    let handle = bridge::start_process_file_batch_job(ProcessFileBatchRequest {
        requests,
        continue_on_error: true,
    })
    .unwrap();

    bridge::cancel_process_file_batch_job(handle.job_id.clone()).unwrap();
    let snapshot = wait_for_job(&handle.job_id);
    assert_eq!(snapshot.state, BatchJobState::Canceled);
    assert!(snapshot.completed_count < snapshot.total_count);
    assert_eq!(snapshot.results.len() as u32, snapshot.completed_count);

    for item in &snapshot.results {
        assert!(item.success);
        assert!(item.result.as_ref().unwrap().did_write);
        assert!(fs::metadata(&item.result.as_ref().unwrap().output_path).is_ok());
    }

    bridge::dispose_process_file_batch_job(handle.job_id).unwrap();
}

#[test]
fn analyze_file_job_returns_sweep_samples() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let handle = bridge::start_analyze_file_job(AnalyzeFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Convert(ConvertOptions {
            target_format: "jpeg".to_string(),
            quality: 80,
            effort: None,
            png_palette: None,
        }),
        qualities: vec![0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
    })
    .unwrap();

    let snapshot = wait_for_analyze_job(&handle.job_id);
    assert_eq!(snapshot.state, BatchJobState::Completed);
    assert_eq!(snapshot.results.len(), 11);
    assert_eq!(snapshot.results.first().unwrap().quality, 0);
    assert_eq!(snapshot.results.last().unwrap().quality, 100);
    assert!(snapshot
        .results
        .iter()
        .all(|sample| !sample.artifact_id.is_empty()));
    assert!(snapshot
        .results
        .iter()
        .all(|sample| fs::metadata(&sample.temp_output_path).is_ok()));

    bridge::dispose_analyze_file_job(handle.job_id).unwrap();
}

#[test]
fn dispose_analyze_file_job_cleans_temp_outputs() {
    let dir = tempdir().unwrap();
    let input_path = dir.path().join("source.png");
    fs::write(&input_path, png_bytes()).unwrap();

    let handle = bridge::start_analyze_file_job(AnalyzeFileRequest {
        input_path: input_path.to_string_lossy().into_owned(),
        operation: ImageOperation::Optimize(OptimizeOptions {
            quality: 80,
            effort: None,
            png_palette: None,
            write_only_if_smaller: true,
        }),
        qualities: vec![0, 50, 100],
    })
    .unwrap();

    let snapshot = wait_for_analyze_job(&handle.job_id);
    let sample_path = snapshot.results.first().unwrap().temp_output_path.clone();
    let artifact_id = snapshot.results.first().unwrap().artifact_id.clone();

    bridge::dispose_analyze_file_job(handle.job_id).unwrap();

    assert!(fs::metadata(&sample_path).is_err());
    let error = bridge::compute_preview_difference_image(PreviewArtifactRequest { artifact_id })
        .unwrap_err();
    assert!(
        error.to_string().contains("unknown preview artifact"),
        "unexpected error: {error}"
    );
}
