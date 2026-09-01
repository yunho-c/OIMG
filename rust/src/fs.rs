use std::fs::{self, FileTimes};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use slimg_core::Format;
use tempfile::NamedTempFile;

use crate::error::{Result, SlimgBridgeError};
use crate::types::ImageOperation;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PreservedFileDates {
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
}

impl PreservedFileDates {
    pub(crate) fn capture(path: &Path) -> Option<Self> {
        let metadata = fs::metadata(path).ok()?;
        Some(Self {
            modified: metadata.modified().ok(),
            created: metadata.created().ok(),
        })
    }
}

pub(crate) fn derive_output_path(
    input: &Path,
    explicit_output: Option<&Path>,
    output_dir: Option<&Path>,
    overwrite: bool,
    operation: &ImageOperation,
    target_format: Format,
) -> Result<PathBuf> {
    let file_name = derived_file_name(input, target_format, operation);
    let derived = match explicit_output {
        Some(path) if path.is_dir() => path.join(&file_name),
        Some(path) => path.to_path_buf(),
        None => match output_dir {
            Some(dir) => dir.join(&file_name),
            None => match operation {
                ImageOperation::Optimize(_) if !overwrite => {
                    sibling_with_suffix(input, "optimized", target_format.extension())
                }
                _ => input.with_extension(target_format.extension()),
            },
        },
    };

    if explicit_output.is_some() && !overwrite && derived == input {
        return Err(SlimgBridgeError::invalid_request(
            "explicit output path matches the input path while overwrite=false",
        ));
    }

    if explicit_output.is_none() && !overwrite && derived == input {
        return Ok(sibling_with_suffix(
            input,
            operation.suffix(),
            target_format.extension(),
        ));
    }

    Ok(derived)
}

pub(crate) fn safe_write_bytes(
    path: &Path,
    bytes: &[u8],
    overwrite: bool,
    preserved_dates: Option<&PreservedFileDates>,
) -> Result<()> {
    if path.exists() {
        if path.is_dir() {
            return Err(SlimgBridgeError::invalid_path(
                path,
                "output path points to a directory",
            ));
        }
        if !overwrite {
            return Err(SlimgBridgeError::invalid_path(
                path,
                "output already exists and overwrite=false",
            ));
        }
    }

    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    fs::create_dir_all(parent)?;

    let mut temp = NamedTempFile::new_in(parent)?;
    temp.write_all(bytes)?;
    temp.flush()?;
    if let Some(dates) = preserved_dates {
        set_file_dates_best_effort(temp.as_file(), dates);
    }

    #[cfg(target_family = "windows")]
    if overwrite && path.exists() {
        fs::remove_file(path)?;
    }

    temp.persist(path).map_err(|error| SlimgBridgeError::Io {
        message: error.error.to_string(),
    })?;
    Ok(())
}

fn set_file_dates_best_effort(file: &fs::File, dates: &PreservedFileDates) {
    let mut times = FileTimes::new();
    let mut has_time = false;

    if let Some(modified) = dates.modified {
        times = times.set_modified(modified);
        has_time = true;
    }

    #[cfg(target_vendor = "apple")]
    if let Some(created) = dates.created {
        use std::os::darwin::fs::FileTimesExt;
        times = times.set_created(created);
        has_time = true;
    }

    #[cfg(windows)]
    if let Some(created) = dates.created {
        use std::os::windows::fs::FileTimesExt;
        times = times.set_created(created);
        has_time = true;
    }

    if has_time {
        let _ = file.set_times(times);
    }
}

pub(crate) fn to_path_buf(value: &str, field_name: &str) -> Result<PathBuf> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(SlimgBridgeError::invalid_request(format!(
            "{field_name} must not be empty"
        )));
    }
    Ok(PathBuf::from(trimmed))
}

fn derived_file_name(input: &Path, target_format: Format, operation: &ImageOperation) -> String {
    if matches!(operation, ImageOperation::Optimize(_)) {
        return sibling_with_suffix(input, "optimized", target_format.extension())
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("output")
            .to_string();
    }

    let stem = file_stem(input);
    format!("{stem}.{}", target_format.extension())
}

fn sibling_with_suffix(input: &Path, suffix: &str, extension: &str) -> PathBuf {
    let stem = file_stem(input);
    input.with_file_name(format!("{stem}.{suffix}.{extension}"))
}

fn file_stem(input: &Path) -> String {
    input
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("output")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ConvertOptions, OptimizeOptions};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    #[test]
    fn optimize_uses_sibling_name() {
        let path = derive_output_path(
            Path::new("/tmp/photo.jpg"),
            None,
            None,
            false,
            &ImageOperation::Optimize(OptimizeOptions {
                quality: 80,
                effort: None,
                png_palette: None,
                jxl_encoder: crate::types::JxlEncoderPreference::Libjxl,
                write_only_if_smaller: true,
            }),
            Format::Jpeg,
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("/tmp/photo.optimized.jpg"));
    }

    #[test]
    fn convert_changes_extension() {
        let path = derive_output_path(
            Path::new("/tmp/photo.jpg"),
            None,
            None,
            false,
            &ImageOperation::Convert(ConvertOptions {
                target_format: "webp".to_string(),
                quality: 80,
                effort: None,
                png_palette: None,
                jxl_encoder: crate::types::JxlEncoderPreference::Libjxl,
            }),
            Format::WebP,
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("/tmp/photo.webp"));
    }

    #[test]
    fn derived_non_overwrite_collision_gets_suffix() {
        let path = derive_output_path(
            Path::new("/tmp/photo.jpg"),
            None,
            None,
            false,
            &ImageOperation::Resize(crate::types::ResizeOptions {
                resize: crate::types::ResizeSpec::Width { value: 100 },
                target_format: None,
                quality: 80,
                effort: None,
                png_palette: None,
                jxl_encoder: crate::types::JxlEncoderPreference::Libjxl,
            }),
            Format::Jpeg,
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("/tmp/photo.resized.jpg"));
    }

    #[test]
    fn safe_write_bytes_preserves_modified_time_for_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let output_path = dir.path().join("photo.jpg");
        fs::write(&output_path, b"original").unwrap();
        let modified = UNIX_EPOCH + Duration::from_secs(1_650_000_000);
        let dates = PreservedFileDates {
            modified: Some(modified),
            created: None,
        };

        safe_write_bytes(&output_path, b"optimized", true, Some(&dates)).unwrap();

        assert_system_time_close(
            fs::metadata(&output_path).unwrap().modified().unwrap(),
            modified,
        );
    }

    #[test]
    fn safe_write_bytes_preserves_modified_time_for_new_output() {
        let dir = tempfile::tempdir().unwrap();
        let output_path = dir.path().join("photo.optimized.jpg");
        let modified = UNIX_EPOCH + Duration::from_secs(1_650_000_123);
        let dates = PreservedFileDates {
            modified: Some(modified),
            created: None,
        };

        safe_write_bytes(&output_path, b"optimized", false, Some(&dates)).unwrap();

        assert_system_time_close(
            fs::metadata(&output_path).unwrap().modified().unwrap(),
            modified,
        );
    }

    #[cfg(any(target_vendor = "apple", windows))]
    #[test]
    fn safe_write_bytes_preserves_created_time_when_supported() {
        let dir = tempfile::tempdir().unwrap();
        let output_path = dir.path().join("photo.optimized.jpg");
        let created = UNIX_EPOCH + Duration::from_secs(1_640_000_000);
        let dates = PreservedFileDates {
            modified: None,
            created: Some(created),
        };

        safe_write_bytes(&output_path, b"optimized", false, Some(&dates)).unwrap();

        let metadata = fs::metadata(&output_path).unwrap();
        let actual_created = metadata.created().unwrap();
        assert_system_time_close(actual_created, created);
    }

    fn assert_system_time_close(actual: SystemTime, expected: SystemTime) {
        let delta = actual
            .duration_since(expected)
            .unwrap_or_else(|_| expected.duration_since(actual).unwrap());
        assert!(
            delta <= Duration::from_secs(2),
            "expected {actual:?} to be within 2s of {expected:?}",
        );
    }
}
