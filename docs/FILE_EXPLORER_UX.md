# File Explorer UX

## Goal

OIMG should support image optimization directly from the user's file explorer
without making the full app feel like it launched.

The ideal file-explorer action should:

- run without opening or foregrounding the main OIMG window;
- avoid showing OIMG as a normal user-launched app in the Dock, taskbar, or app
  switcher when the user only invoked a file action;
- show a small completion toast with useful optimization statistics;
- eventually offer a lightweight strength choice before running.

This is a UX direction document, not a committed implementation plan. Each
desktop platform has different extension and packaging constraints, so the best
implementation is platform-specific.

## Target Experience

The default action should be quick and quiet:

1. The user right-clicks one or more image files in Finder, File Explorer, or a
   Linux file manager.
2. The user chooses an OIMG action such as `Compress image`, `Save as JPG`, or
   `Save as PNG`.
3. OIMG optimizes the selected files in the background.
4. A compact toast reports the result: processed count, failures if any,
   original size, optimized size, savings, output format, and preset/quality.

For a future interactive action, OIMG could show a minimal picker before
optimization. The picker should not be the full Flutter app. It should be a tiny
native or helper-owned surface with one of these controls:

- a three-way preset selector: `Minimal loss`, `Balanced`, `Efficient`;
- a compact slider for optimization strength;
- separate context-menu actions for each preset, where the platform makes
  pre-run UI awkward.

The preset names should map to existing OIMG settings rather than introduce a
second compression model. For example, `Balanced` can remain the default service
preset while `Efficient` biases toward smaller files and `Minimal loss` biases
toward quality preservation.

## Current Behavior

macOS currently implements Finder actions as app-provided Services. The services
are declared in `macos/Runner/Info.plist` with `NSServices`, `NSPortName = OIMG`,
and `NSMessage = runCompressionService`, and they are handled by
`CompressionServiceProvider` in the main app process.

That implementation is functional and simple, but it explains the current UX:
when Finder invokes the service, macOS may launch OIMG as the service provider.
Because OIMG is a normal foreground app, the Dock icon and main window can
appear or come forward.

Windows currently has Open With/file association support, not equivalent
background Explorer compression actions. Linux has desktop metadata and release
verification notes for file-manager integration, but practical context-menu
support is file-manager-specific.

## macOS

The current Finder Services approach is acceptable for a first implementation,
but it is not ideal for background UX because the service is hosted by the main
app.

Recommended direction:

- Keep the existing Services as the compatibility path.
- Add a service-only execution path that can process selected files without
  constructing or foregrounding the Flutter window.
- Prefer a small native helper or XPC-style helper for the work boundary if the
  main app cannot reliably stay hidden during service invocation.
- Keep the compression implementation shared with the existing Rust service FFI;
  do not add a second optimizer.

Toast options:

- Use native macOS notifications for completion summaries.
- If Notification Center permission is undesirable, use a short-lived helper UI
  window near the active display instead.
- The toast should include processed count, failures, size savings, and selected
  preset/quality.

Strength-selection options:

- Easiest: add separate Services for each preset, such as
  `Compress image - Balanced` and `Compress image - Efficient`.
- Better UX: show a small native picker window from the helper, then run the same
  Rust service request with the chosen preset.
- Avoid launching the full Flutter UI just to choose strength.

Sandbox and distribution notes:

- Finder-provided file URLs must continue to use security-scoped access.
- Sibling-output actions such as `Save as JPG` and `Save as PNG` need manual
  MAS-signed verification because they create files next to the selected input.
- A local ad-hoc build is not enough to prove final Mac App Store behavior.

## Windows

Windows should use a helper-driven context-menu path rather than starting the
Flutter window for each Explorer command.

Recommended direction:

- Add Explorer actions through the packaging mechanism appropriate to the
  distribution channel.
- For Microsoft Store/MSIX, prefer supported package extensions, app execution
  aliases, or protocol activation patterns over installer-time registry edits.
- For a classic installer, registry-backed shell verbs can invoke a bundled OIMG
  helper executable.
- The helper should call the shared Rust optimization path and exit after
  reporting status.

Toast options:

- Use Windows toast notifications with OIMG's app identity.
- Include processed count, failures, original size, optimized size, savings, and
  preset/quality.
- For non-MSIX installers, make sure the app identity and shortcut registration
  are sufficient for toast attribution.

Strength-selection options:

- Easiest: provide separate Explorer verbs for common presets.
- Better UX: launch a compact native picker helper, then run the selected preset.
- Avoid using the main Flutter window as the picker unless the user explicitly
  chooses an `Open in OIMG` action.

Store and installer notes:

- MSIX and classic installer paths may need different registration mechanisms.
- Context-menu registration should be per-user where possible.
- The helper should tolerate long path names, multiple selected files, and paths
  containing spaces or non-ASCII characters.

## Linux

Linux file-manager integration is not one uniform API. The implementation should
be explicit about which desktop environments and file managers are supported.

Recommended direction:

- Treat Nautilus/GNOME, Dolphin/KDE, and other file managers as separate
  integration targets.
- Use a small OIMG CLI/helper as the common execution target.
- Keep the helper independent of the Flutter window.
- Package file-manager integration files only for environments where they are
  known to work.

Nautilus/GNOME path:

- Provide a Nautilus script or extension entry that passes selected file paths to
  the helper.
- If a real extension is added, keep it thin and delegate compression to the
  helper.

Dolphin/KDE path:

- Provide service-menu `.desktop` files that invoke the helper with selected
  paths.
- Prefer separate service-menu entries for fixed presets if interactive UI is
  unreliable.

Other file managers:

- Document best-effort setup through custom actions where supported.
- Do not claim universal Linux context-menu support unless each file manager is
  tested.

Toast options:

- Use the Freedesktop Notifications interface, either directly or through a
  `notify-send`-style helper.
- Fall back to terminal/stdout output only for explicitly CLI-oriented usage.

Strength-selection options:

- Most portable: separate actions for `Minimal loss`, `Balanced`, and
  `Efficient`.
- Better desktop UX: a small GTK or Qt helper dialog, packaged with the app and
  invoked by the file-manager action.

Packaging notes:

- Debian packages, Flatpak, AppImage, and distro packages may each need different
  integration installation paths.
- Flatpak-style sandboxing may require portal-aware file access rather than raw
  host paths.

## Shared Helper Shape

All platforms should converge on the same conceptual helper contract:

- input: action, preset/quality, and selected file paths;
- output: per-file success/failure, output paths, original sizes, optimized
  sizes, and aggregate savings;
- behavior: no Flutter window unless explicitly requested;
- implementation: call the existing Rust optimization pipeline;
- failure reporting: return structured errors and show a compact toast when a
  desktop notification system is available.

This keeps Explorer/Finder/file-manager features from becoming separate
compression implementations.

## Verification Checklist

For every supported platform and packaging channel:

- invoke each file-explorer action while OIMG is closed;
- verify whether the main window, Dock icon, taskbar button, or app switcher
  entry appears;
- invoke each action while OIMG is already running;
- test one file and multiple selected files;
- test overwrite and sibling-output actions;
- verify files in common protected locations such as Desktop, Documents, and
  Downloads;
- verify paths with spaces and non-ASCII characters;
- verify completion toast contents and failure reporting;
- verify preset or strength selection, if enabled;
- confirm the implementation uses the shared Rust optimization path.
