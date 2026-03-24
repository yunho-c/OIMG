# Build Strategy

## Goal

Ship OIMG on macOS, Windows, and Linux with a Flutter desktop shell and a Rust core exposed through Flutter Rust Bridge, while minimizing platform-specific linker and packaging failures.

## Recommendation

Use this boundary by default:

- Keep the outer Rust artifact dynamic.
  - macOS: framework / `dylib`
  - Windows: `dll`
  - Linux: `so`
- Prefer static linking for transitive native codec dependencies inside the Rust artifact whenever feasible.
- Only add platform-specific runtime bundling for a dependency when static linking is not practical.

In short:

- dynamic at the app boundary
- static inside the Rust/native dependency graph where possible

## Why This Is The Preferred Approach

### 1. Static Rust archives do not scale well with native dependency-heavy crates

OIMG depends on `slimg-core`, which pulls in native C/C++ codec stacks such as:

- `dav1d`
- `libjxl`
- `hwy`
- `brotli`
- `mozjpeg`
- `libwebp`

When those dependencies sit behind a Rust `staticlib`, the host build system must still receive all required native link inputs and link flags. In practice, that is brittle.

The macOS investigation showed exactly this failure mode:

- `liboimg_rust.a` could be produced successfully
- Cargo emitted the needed native link directives
- CocoaPods/Xcode did not propagate those transitive native link requirements cleanly into the final app link
- the result was unresolved `dav1d`, C++, and JPEG XL / highway symbols

This class of problem is not macOS-specific in spirit. It is the kind of integration issue that tends to recur differently on each platform.

### 2. A dynamic Rust boundary simplifies host integration

If Rust links its native dependencies first and produces a coherent dynamic library, the host app usually has a simpler job:

- Flutter/native runner links one Rust library artifact
- Cargo handles the deeper native dependency graph
- platform packaging deals with one top-level Rust library instead of a partially exploded archive dependency set

This is a better fit for FRB when the Rust crate is no longer “pure Rust” and starts to include substantial native libraries.

### 3. Static transitive deps are still valuable

Using a dynamic Rust boundary does not mean accepting dynamic native dependencies everywhere.

The preferred outcome is:

- `dav1d`, `libjxl`, etc. statically absorbed into the Rust dynamic artifact when possible
- no dependence on Homebrew/system-installed codec dylibs/dlls/so files at runtime unless necessary

This gives the cleanest distribution story:

- fewer external runtime dependencies
- fewer loader path issues
- less platform-specific copying and signing work

## Platform Strategy

### macOS

Use the current working approach as the reference model:

- build the Rust artifact as a dynamic framework payload
- force `dav1d` source build with static linking
- avoid depending on a Homebrew `libdav1d` at runtime

Why:

- the old `staticlib` route failed because native Cargo link directives were not cleanly propagated through the CocoaPods/Xcode integration
- the dynamic framework route avoids that failure mode

### Windows

Prefer the same top-level boundary:

- Rust exposed as a `dll`
- native codec dependencies statically linked into that DLL where feasible

Expect Windows-specific packaging work for:

- import library / DLL handling
- copying runtime DLLs when a dependency cannot be static
- MSVC linker behavior
- installer or app-local distribution layout

The strategy should still remain:

- one Rust DLL at the app boundary
- keep subordinate native libraries static if possible

### Linux

Prefer the same top-level boundary:

- Rust exposed as a `so`
- native codec dependencies statically linked into that shared object where feasible

Expect Linux-specific packaging work for:

- `rpath` / loader path behavior
- distro compatibility
- install layout for packaged builds

Again, the strategy should remain:

- one Rust shared object at the app boundary
- keep subordinate native libraries static if possible

## What To Avoid As The Main Plan

Do not make “fix the Rust `staticlib` path everywhere” the default cross-platform strategy.

Reasons:

- it pushes Cargo’s transitive native dependency graph onto each host platform linker
- it requires the Flutter/native build system to understand and preserve many nontrivial Rust-emitted link requirements
- it is likely to lead to a different debugging story on each platform

It may still be worth investigating for upstream FRB/Cargokit improvement, but it is not the lowest-risk path for OIMG shipping on three desktop platforms.

## Decision Rule

When integrating a new native dependency, prefer this order:

1. Can it be statically linked into the Rust dynamic artifact?
2. If not, can it be bundled predictably with the app on each target platform?
3. If not, reconsider the dependency choice or feature scope.

## Practical Guidance For OIMG

For OIMG specifically:

- Keep the current macOS dynamic-library integration.
- Treat that as the reference architecture for desktop.
- As Windows and Linux are brought up, try to match the same architectural boundary first.
- Investigate static transitive linkage for codec dependencies early, before adding platform-specific runtime bundling logic.
- Only invest in the `staticlib` FRB/Cargokit path if there is a strong upstreaming goal or a demonstrated platform advantage.

## Summary

The best cross-platform strategy is:

- dynamic Rust library at the desktop app boundary
- static native codec dependencies inside that Rust library whenever possible
- platform-specific packaging only for the remaining unavoidable dynamic pieces

That approach is the most robust fit for OIMG’s dependency graph and the least likely to multiply linker problems across macOS, Windows, and Linux.
