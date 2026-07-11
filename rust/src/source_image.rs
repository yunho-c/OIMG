use slimg_core::{decode, Format, ImageData};

use crate::error::{Result, SlimgBridgeError};
use crate::types::ColorProfileMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SourceFormat {
    Core(Format),
    Heic,
}

impl SourceFormat {
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Core(Format::Jpeg) => "jpeg",
            Self::Core(Format::Png) => "png",
            Self::Core(Format::WebP) => "webp",
            Self::Core(Format::Avif) => "avif",
            Self::Core(Format::Jxl) => "jxl",
            Self::Core(Format::Qoi) => "qoi",
            Self::Heic => "heic",
        }
    }

    pub(crate) fn core(self) -> Result<Format> {
        match self {
            Self::Core(format) => Ok(format),
            Self::Heic => Err(SlimgBridgeError::UnsupportedFormat {
                format: self.id().to_string(),
            }),
        }
    }
}

pub(crate) struct SourceImage {
    pub(crate) image: ImageData,
    pub(crate) format: SourceFormat,
}

pub(crate) fn decode_source_image(data: &[u8]) -> Result<SourceImage> {
    decode_source_image_with_color(data, ColorProfileMode::Preserve)
}

pub(crate) fn decode_source_image_with_color(
    data: &[u8],
    mode: ColorProfileMode,
) -> Result<SourceImage> {
    if is_heic(data) {
        return decode_heic(data).map(|image| SourceImage {
            image,
            format: SourceFormat::Heic,
        });
    }

    let (mut image, format) = decode(data)?;
    let source_icc = crate::metadata::inspect(data).icc;
    if let Some(icc) = source_icc.as_deref() {
        crate::metadata::validate_icc(icc)?;
    }
    if mode == ColorProfileMode::BakeToSrgb {
        if let Some(icc) = source_icc {
            image.data = crate::metadata::convert_rgba_to_srgb(&image.data, &icc)?;
        }
    }
    Ok(SourceImage {
        image,
        format: SourceFormat::Core(format),
    })
}

fn is_heic(data: &[u8]) -> bool {
    if data.len() < 12 || &data[4..8] != b"ftyp" {
        return false;
    }

    data[8..].chunks_exact(4).any(|brand| {
        matches!(
            brand,
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" | b"hevm" | b"hevs"
        )
    })
}

#[cfg(target_os = "macos")]
fn decode_heic(data: &[u8]) -> Result<ImageData> {
    macos_imageio::decode_heic(data)
}

#[cfg(not(target_os = "macos"))]
fn decode_heic(_data: &[u8]) -> Result<ImageData> {
    Err(SlimgBridgeError::UnsupportedFormat {
        format: "heic".to_string(),
    })
}

#[cfg(target_os = "macos")]
mod macos_imageio {
    use std::ffi::c_void;
    use std::ptr;

    use slimg_core::ImageData;

    use crate::error::{Result, SlimgBridgeError};

    type CFIndex = isize;
    type CFAllocatorRef = *const c_void;
    type CFDataRef = *const c_void;
    type CFDictionaryRef = *const c_void;
    type CGImageSourceRef = *const c_void;
    type CGImageRef = *const c_void;
    type CGColorSpaceRef = *mut c_void;
    type CGContextRef = *mut c_void;
    type CGFloat = f64;

    #[repr(C)]
    struct CGPoint {
        x: CGFloat,
        y: CGFloat,
    }

    #[repr(C)]
    struct CGSize {
        width: CGFloat,
        height: CGFloat,
    }

    #[repr(C)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }

    const K_CG_IMAGE_ALPHA_PREMULTIPLIED_LAST: u32 = 1;
    const K_CG_BITMAP_BYTE_ORDER_32_BIG: u32 = 4 << 12;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFDataCreate(allocator: CFAllocatorRef, bytes: *const u8, length: CFIndex) -> CFDataRef;
        fn CFRelease(cf: *const c_void);
    }

    #[link(name = "ImageIO", kind = "framework")]
    extern "C" {
        fn CGImageSourceCreateWithData(
            data: CFDataRef,
            options: CFDictionaryRef,
        ) -> CGImageSourceRef;
        fn CGImageSourceCreateImageAtIndex(
            source: CGImageSourceRef,
            index: usize,
            options: CFDictionaryRef,
        ) -> CGImageRef;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGImageGetWidth(image: CGImageRef) -> usize;
        fn CGImageGetHeight(image: CGImageRef) -> usize;
        fn CGImageRelease(image: CGImageRef);

        fn CGColorSpaceCreateDeviceRGB() -> CGColorSpaceRef;
        fn CGColorSpaceRelease(space: CGColorSpaceRef);

        fn CGBitmapContextCreate(
            data: *mut c_void,
            width: usize,
            height: usize,
            bits_per_component: usize,
            bytes_per_row: usize,
            space: CGColorSpaceRef,
            bitmap_info: u32,
        ) -> CGContextRef;
        fn CGContextDrawImage(context: CGContextRef, rect: CGRect, image: CGImageRef);
        fn CGContextRelease(context: CGContextRef);
    }

    pub(super) fn decode_heic(data: &[u8]) -> Result<ImageData> {
        let cf_data = unsafe { CFDataCreate(ptr::null(), data.as_ptr(), data.len() as CFIndex) };
        if cf_data.is_null() {
            return Err(decode_error("unable to create ImageIO data source"));
        }

        let source = unsafe {
            CGImageSourceCreateWithData(cf_data, ptr::null::<c_void>() as CFDictionaryRef)
        };
        unsafe { CFRelease(cf_data) };
        if source.is_null() {
            return Err(decode_error("ImageIO could not open HEIC data"));
        }

        let image = unsafe {
            CGImageSourceCreateImageAtIndex(source, 0, ptr::null::<c_void>() as CFDictionaryRef)
        };
        unsafe { CFRelease(source) };
        if image.is_null() {
            return Err(decode_error("ImageIO could not decode HEIC image"));
        }

        let result = draw_image_to_rgba(image);
        unsafe { CGImageRelease(image) };
        result
    }

    fn draw_image_to_rgba(image: CGImageRef) -> Result<ImageData> {
        let width = unsafe { CGImageGetWidth(image) };
        let height = unsafe { CGImageGetHeight(image) };
        if width == 0 || height == 0 {
            return Err(decode_error("ImageIO decoded an empty HEIC image"));
        }
        let width_u32 =
            u32::try_from(width).map_err(|_| decode_error("decoded HEIC width is too large"))?;
        let height_u32 =
            u32::try_from(height).map_err(|_| decode_error("decoded HEIC height is too large"))?;

        let byte_count = width
            .checked_mul(height)
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or_else(|| decode_error("decoded HEIC dimensions are too large"))?;
        let bytes_per_row = width
            .checked_mul(4)
            .ok_or_else(|| decode_error("decoded HEIC width is too large"))?;
        let mut rgba = vec![0_u8; byte_count];

        let color_space = unsafe { CGColorSpaceCreateDeviceRGB() };
        if color_space.is_null() {
            return Err(decode_error("unable to create ImageIO color space"));
        }

        let context = unsafe {
            CGBitmapContextCreate(
                rgba.as_mut_ptr().cast(),
                width,
                height,
                8,
                bytes_per_row,
                color_space,
                K_CG_BITMAP_BYTE_ORDER_32_BIG | K_CG_IMAGE_ALPHA_PREMULTIPLIED_LAST,
            )
        };
        unsafe { CGColorSpaceRelease(color_space) };
        if context.is_null() {
            return Err(decode_error("unable to create ImageIO bitmap context"));
        }

        let rect = CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize {
                width: width as CGFloat,
                height: height as CGFloat,
            },
        };
        unsafe {
            CGContextDrawImage(context, rect, image);
            CGContextRelease(context);
        }

        unpremultiply_rgba(&mut rgba);
        Ok(ImageData::new(width_u32, height_u32, rgba))
    }

    fn unpremultiply_rgba(rgba: &mut [u8]) {
        for pixel in rgba.chunks_exact_mut(4) {
            let alpha = pixel[3];
            if alpha == 0 || alpha == 255 {
                continue;
            }

            let alpha = u16::from(alpha);
            for channel in &mut pixel[..3] {
                *channel = ((u16::from(*channel) * 255 + alpha / 2) / alpha).min(255) as u8;
            }
        }
    }

    fn decode_error(message: impl Into<String>) -> SlimgBridgeError {
        SlimgBridgeError::Decode {
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_heic_brands() {
        let mut data = b"\0\0\0\x18ftypheic\0\0\0\0mif1heic".to_vec();
        assert!(is_heic(&data));

        data[8..12].copy_from_slice(b"avif");
        assert!(is_heic(&data));
    }

    #[test]
    fn ignores_non_heic_brands() {
        assert!(!is_heic(b""));
        assert!(!is_heic(b"\0\0\0\x18ftypavif\0\0\0\0mif1avif"));
        assert!(!is_heic(b"\0\0\0\x18ftypmif1\0\0\0\0msf1iso8"));
    }
}
