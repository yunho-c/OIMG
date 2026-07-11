use img_parts::{DynImage, ImageEXIF, ImageICC};
use moxcms::{ColorProfile, Layout, TransformOptions};

use crate::error::{Result, SlimgBridgeError};
use crate::types::EmbeddedMetadata;

pub(crate) struct SourceMetadata {
    pub(crate) icc: Option<Vec<u8>>,
    pub(crate) exif: Option<Vec<u8>>,
    pub(crate) icc_size: u64,
    pub(crate) exif_size: u64,
}

pub(crate) fn inspect(data: &[u8]) -> SourceMetadata {
    let parsed = DynImage::from_bytes(data.to_vec().into()).ok().flatten();
    let Some(image) = parsed else {
        return SourceMetadata {
            icc: None,
            exif: None,
            icc_size: 0,
            exif_size: 0,
        };
    };
    let icc = image.icc_profile().map(|value| value.to_vec());
    let exif = image.exif().map(|value| value.to_vec());
    SourceMetadata {
        icc_size: removable_size(data, true),
        exif_size: removable_size(data, false),
        icc,
        exif,
    }
}

fn removable_size(data: &[u8], icc: bool) -> u64 {
    let Ok(Some(mut image)) = DynImage::from_bytes(data.to_vec().into()) else {
        return 0;
    };
    let original = image.len();
    if icc {
        if image.icc_profile().is_none() {
            return 0;
        }
        image.set_icc_profile(None);
    } else {
        if image.exif().is_none() {
            return 0;
        }
        image.set_exif(None);
    }
    original.saturating_sub(image.len()) as u64
}

pub(crate) fn embedded_summary(
    label: &str,
    payload: Option<&[u8]>,
    size_bytes: u64,
) -> Option<EmbeddedMetadata> {
    payload.map(|_| EmbeddedMetadata {
        label: label.to_string(),
        size_bytes,
    })
}

pub(crate) fn srgb_profile_bytes() -> Result<Vec<u8>> {
    ColorProfile::new_srgb()
        .encode()
        .map_err(|error| color_error(format!("sRGB profile encode failed: {error}")))
}

pub(crate) fn convert_rgba_to_srgb(rgba: &[u8], source_icc: &[u8]) -> Result<Vec<u8>> {
    let source = parse_profile(source_icc)?;
    let destination = ColorProfile::new_srgb();
    let transform = source
        .create_transform_8bit(
            Layout::Rgba,
            &destination,
            Layout::Rgba,
            TransformOptions::default(),
        )
        .map_err(|error| color_error(format!("color transform setup failed: {error}")))?;
    let mut output = vec![0; rgba.len()];
    transform
        .transform(rgba, &mut output)
        .map_err(|error| color_error(format!("color transform failed: {error}")))?;
    Ok(output)
}

pub(crate) fn validate_icc(source_icc: &[u8]) -> Result<()> {
    parse_profile(source_icc).map(|_| ())
}

fn parse_profile(source_icc: &[u8]) -> Result<ColorProfile> {
    ColorProfile::new_from_slice(source_icc)
        .map_err(|error| color_error(format!("invalid source color profile: {error}")))
}

pub(crate) fn write_metadata(
    output_bytes: Vec<u8>,
    exif: Option<&[u8]>,
    icc: Option<&[u8]>,
) -> Result<Vec<u8>> {
    if exif.is_none() && icc.is_none() {
        return Ok(output_bytes);
    }
    let Some(mut output) = DynImage::from_bytes(output_bytes.clone().into()).map_err(|error| {
        SlimgBridgeError::Internal {
            message: format!("metadata output parse failed: {error}"),
        }
    })?
    else {
        return Err(SlimgBridgeError::UnsupportedFormat {
            format: "metadata-preserving output".to_string(),
        });
    };
    output.set_exif(exif.map(|value| value.to_vec().into()));
    output.set_icc_profile(icc.map(|value| value.to_vec().into()));
    let mut encoded = Vec::new();
    output
        .encoder()
        .write_to(&mut encoded)
        .map_err(|error| SlimgBridgeError::Internal {
            message: format!("metadata encode failed: {error}"),
        })?;
    Ok(encoded)
}

fn color_error(message: String) -> SlimgBridgeError {
    SlimgBridgeError::Decode { message }
}
