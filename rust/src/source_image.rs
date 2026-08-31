use std::io::{BufRead, Cursor, Seek};

use imagesize::{Compression, ImageError, ImageType};
use slimg_core::{codec::get_codec, Format, ImageData};

use crate::error::{Result, SlimgBridgeError};

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

pub(crate) fn detect_source_format<R: BufRead + Seek>(
    reader: &mut R,
) -> Result<(SourceFormat, ImageType)> {
    let image_type = imagesize::reader_type(&mut *reader).map_err(map_probe_error)?;
    let format = match image_type {
        ImageType::Jpeg => SourceFormat::Core(Format::Jpeg),
        ImageType::Png => SourceFormat::Core(Format::Png),
        ImageType::Webp => SourceFormat::Core(Format::WebP),
        ImageType::Jxl => SourceFormat::Core(Format::Jxl),
        ImageType::Qoi => SourceFormat::Core(Format::Qoi),
        ImageType::Heif(Compression::Av1) => SourceFormat::Core(Format::Avif),
        #[cfg(target_os = "macos")]
        ImageType::Heif(Compression::Hevc) => SourceFormat::Heic,
        #[cfg(not(target_os = "macos"))]
        ImageType::Heif(Compression::Hevc) => {
            return Err(SlimgBridgeError::UnsupportedFormat {
                format: "heic".to_string(),
            })
        }
        _ => {
            return Err(SlimgBridgeError::UnknownFormat {
                detail: "unsupported image container".to_string(),
            })
        }
    };
    Ok((format, image_type))
}

pub(crate) fn decode_source_image(data: &[u8]) -> Result<SourceImage> {
    let (format, _) = detect_source_format(&mut Cursor::new(data))?;
    let image = match format {
        SourceFormat::Core(format) => get_codec(format).decode(data)?,
        SourceFormat::Heic => decode_heic(data)?,
    };
    Ok(SourceImage { image, format })
}

pub(crate) fn map_probe_error(error: ImageError) -> SlimgBridgeError {
    match error {
        ImageError::NotSupported => SlimgBridgeError::UnknownFormat {
            detail: "unrecognized image header".to_string(),
        },
        ImageError::CorruptedImage => SlimgBridgeError::Decode {
            message: "image header is incomplete or corrupt".to_string(),
        },
        ImageError::IoError(error) => SlimgBridgeError::Io {
            message: error.to_string(),
        },
    }
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
        let data = b"\0\0\0\x18ftypheic\0\0\0\0mif1heic";
        let detected = detect_source_format(&mut Cursor::new(data));
        #[cfg(target_os = "macos")]
        assert!(matches!(detected, Ok((SourceFormat::Heic, _))));
        #[cfg(not(target_os = "macos"))]
        assert!(matches!(
            detected,
            Err(SlimgBridgeError::UnsupportedFormat { format }) if format == "heic"
        ));
    }

    #[test]
    fn detects_avif_as_a_core_format() {
        let data = b"\0\0\0\x18ftypavif\0\0\0\0mif1avif";
        assert!(matches!(
            detect_source_format(&mut Cursor::new(data)),
            Ok((SourceFormat::Core(Format::Avif), _))
        ));
    }
}
