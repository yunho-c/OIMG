# OIMG FRB Bridge

This crate exposes a desktop-focused `flutter_rust_bridge` API on top of `slimg-core`.

## JPEG backend and Slimg checkout

OIMG selects standalone Jpegli for JPEG encoding and decoding. Both `slimg-core`
and `slimg-exec` disable Cargo default features and explicitly enable
`jpeg-backend-jpegli`, so the executor cannot implicitly enable MozJPEG.

Release workflows pin Slimg to `f43ceaa422eb0e7f238b1757e60637d3d851e55c`.
Use that revision in the sibling `../slimg` checkout for local builds, with its
submodules initialized (`git -C ../slimg submodule update --init --recursive`).
CI builds the native libraries from those pinned sources. Offline/prebuilt builds
can instead set `JPEGLI_SYS_DIR` and `LIBJXL_SYS_DIR` to the matching Slimg native
artifacts; Jpegli requires `slimg-jpegli-sys` 0.1.1 / shim ABI 2. See
[Slimg's packaging instructions](https://github.com/yunho-c/slimg/blob/f43ceaa422eb0e7f238b1757e60637d3d851e55c/crates/jpegli-sys/README.md).

The existing effort setting reaches conversion, optimization, previews and batch
jobs. Jpegli uses sequential JPEG with fixed Huffman tables at 0–24, sequential
with optimized tables at 25–49, progressive level 1 at 50–74, and progressive
level 2 at 75–100. Both progressive tiers optimize Huffman tables. OIMG's default
effort 50 selects level 1; requests with no effort retain Slimg's level 2 default.
Effort leaves quality and chroma settings unchanged. Compression and speed vary
by image. JPEG encode/decode selection remains coupled in Slimg.

`cargo test --manifest-path rust/Cargo.toml --test jpegli` checks actual JPEG
scan structure and consistent bytes through the bridge, previews and executor.

## Surface

- `version`
- `supported_formats`
- `inspect_file`
- `inspect_bytes`
- `preview_file`
- `process_file`
- `process_bytes`
- `process_files`

The bridge keeps request validation and image pipeline behavior in Rust. Dart receives typed request/result models and encoded image bytes only.

## Output Rules

- `Convert` with no `output_path` changes the extension to the target format.
- `Optimize` with `overwrite=false` writes `name.optimized.ext`.
- `Resize`, `Crop`, and `Extend` keep the source format unless `target_format` is set.
- When an auto-derived non-overwrite path would collide with the input file, the bridge writes a suffixed sibling such as `name.resized.ext`.
- `write_only_if_smaller` keeps the original file untouched when the optimized payload is not smaller.

## Flutter Usage

```dart
import 'package:oimg/src/rust/slimg_bridge.dart';

final bridge = SlimgBridge();

final result = await bridge.processFile(
  request: ProcessFileRequest(
    inputPath: '/tmp/photo.jpg',
    overwrite: false,
    operation: ImageOperation.convert(
      ConvertOptions(targetFormat: 'webp', quality: 80),
    ),
  ),
);
```

## Desktop Packaging

- macOS: the generated `oimg_rust.framework` or dylib must be bundled with the app runner.
- Windows: copy the generated Rust DLL next to `Runner.exe`.
- Linux: ship the generated `.so` with the runner bundle and ensure the loader can resolve it.

The repo already uses `rust_builder/` and Cargokit for native artifact integration.
