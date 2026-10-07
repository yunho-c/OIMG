use std::fs;

use oimg_rust::api::bridge::{
    self, ConvertOptions, ImageOperation, OptimizeOptions, PreviewFileRequest, ProcessBytesRequest,
    ProcessFileBatchRequest, ProcessFileRequest,
};
use slimg_core::{convert, decode, Format, ImageData, PipelineOptions};
use tempfile::tempdir;

fn source_png() -> Vec<u8> {
    let mut rgba = Vec::new();
    for y in 0..49 {
        for x in 0..65 {
            rgba.extend_from_slice(&[
                (x * 7 + y * 3) as u8,
                (x * 2 + y * 11) as u8,
                (x * y) as u8,
                255,
            ]);
        }
    }
    convert(
        &ImageData::new(65, 49, rgba),
        &PipelineOptions {
            format: Format::Png,
            quality: 80,
            effort: Some(0),
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

fn convert_jpeg(effort: Option<u8>) -> ImageOperation {
    ImageOperation::Convert(ConvertOptions {
        target_format: "jpeg".into(),
        quality: 80,
        effort,
        png_palette: None,
    })
}

fn assert_jpeg_mode(jpeg: &[u8], effort: Option<u8>) {
    assert_eq!(&jpeg[..2], &[0xff, 0xd8]);
    let effort = effort.unwrap_or(100);
    let expected_frame = if effort < 50 { 0xc0 } else { 0xc2 };
    let expected_scans = if effort < 50 {
        1
    } else if effort < 75 {
        9
    } else {
        15
    };
    let (mut frame, mut scans, mut ended) = (None, 0, false);
    let mut pos = 2;
    while pos < jpeg.len() {
        if jpeg[pos] != 0xff {
            pos += 1;
            continue;
        }
        while jpeg[pos] == 0xff {
            pos += 1;
        }
        let marker = jpeg[pos];
        pos += 1;
        match marker {
            0x00 | 0xd0..=0xd7 => continue,
            0xd9 => {
                ended = true;
                break;
            }
            0xc0..=0xc2 => frame = Some(marker),
            0xda => scans += 1,
            _ => {}
        }
        // Skip marker payloads so their bytes cannot be mistaken for scans.
        let len = u16::from_be_bytes([jpeg[pos], jpeg[pos + 1]]) as usize;
        assert!(len >= 2);
        pos += len;
    }
    assert!(ended);
    assert_eq!(frame, Some(expected_frame), "effort {effort}");
    assert_eq!(scans, expected_scans, "effort {effort}");
    let (decoded, format) = decode(jpeg).unwrap();
    assert_eq!(format, Format::Jpeg);
    assert_eq!((decoded.width, decoded.height), (65, 49));
}

fn check_bridge_routes(
    source: Vec<u8>,
    extension: &str,
    operation: fn(Option<u8>) -> ImageOperation,
) {
    let dir = tempdir().unwrap();
    let input = dir.path().join(format!("source.{extension}"));
    fs::write(&input, &source).unwrap();
    let mut requests = Vec::new();
    let mut expected = Vec::new();
    for effort in [Some(0), Some(25), Some(50), Some(75), None] {
        let operation = operation(effort);
        let encoded = bridge::process_bytes(ProcessBytesRequest {
            data: source.clone(),
            operation: operation.clone(),
        })
        .unwrap();
        assert_jpeg_mode(&encoded.encoded_bytes, effort);

        let preview = bridge::preview_file(PreviewFileRequest {
            input_path: input.to_string_lossy().into_owned(),
            operation: operation.clone(),
        })
        .unwrap();
        assert_eq!(preview.encoded_bytes, encoded.encoded_bytes);
        bridge::dispose_preview_artifact(preview.artifact_id).unwrap();

        let output = dir.path().join(format!("output-{}.jpg", expected.len()));
        requests.push(ProcessFileRequest {
            input_path: input.to_string_lossy().into_owned(),
            output_path: Some(output.to_string_lossy().into_owned()),
            overwrite: false,
            preserve_file_dates: false,
            preserve_exif: false,
            preserve_color_profile: false,
            operation,
        });
        expected.push((output, encoded.encoded_bytes));
    }
    // Distinguish the fixed/optimized sequential tiers, and preserve None.
    assert_ne!(expected[0].1, expected[1].1);
    assert_eq!(expected[3].1, expected[4].1);
    let results = bridge::process_file_batch(ProcessFileBatchRequest {
        requests,
        // Exercise the slimg-exec scheduler, not only the serial fast path.
        continue_on_error: true,
    })
    .unwrap();
    assert_eq!(results.len(), expected.len());
    for (result, (output, bytes)) in results.iter().zip(expected) {
        assert!(result.success, "{result:?}");
        assert!(result.result.as_ref().unwrap().did_write);
        assert_eq!(fs::read(output).unwrap(), bytes);
    }
}

#[test]
fn jpegli_effort_reaches_conversion_preview_and_batch() {
    check_bridge_routes(source_png(), "png", convert_jpeg);
}

#[test]
fn jpegli_effort_reaches_optimization_preview_and_batch() {
    let source = bridge::process_bytes(ProcessBytesRequest {
        data: source_png(),
        operation: convert_jpeg(None),
    })
    .unwrap();
    check_bridge_routes(source.encoded_bytes, "jpg", |effort| {
        ImageOperation::Optimize(OptimizeOptions {
            quality: 80,
            effort,
            png_palette: None,
            write_only_if_smaller: false,
        })
    });
}
