# macOS CI/CD Setup

One-time setup required before the GitHub macOS release workflow can build signed and notarized DMGs.

## GitHub Secrets

Add these secrets in GitHub under **Settings > Secrets and variables > Actions > Repository secrets**.

| Secret | Purpose |
| --- | --- |
| `CI_REPO_TOKEN` | GitHub token with read access to `yunho-c/slimg`, `yunho-c/tjdistler-iqa-fork`, and `yunho-c/irondash`. |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` certificate. |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_SIGN_IDENTITY` | Exact signing identity, for example `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ASC_KEY_ID` | App Store Connect API key ID. |
| `APPLE_ASC_ISSUER_ID` | App Store Connect issuer ID. |
| `APPLE_ASC_API_KEY_P8` | Full contents of the App Store Connect API private key file. |
| `KEYCHAIN_PASSWORD` | Random password used only for the temporary CI keychain. |

## GitHub Token

Create a fine-grained personal access token that can read the sibling repositories:

- `yunho-c/slimg`
- `yunho-c/tjdistler-iqa-fork`
- `yunho-c/irondash`

Give it read-only repository contents access, then save it as `CI_REPO_TOKEN`.

## Developer ID Certificate

Use an Apple Developer account that has a **Developer ID Application** certificate.

1. Open **Keychain Access** on the Mac that has the certificate and private key.
2. Select the **Developer ID Application** certificate and its private key.
3. Export them as a `.p12` file.
4. Set a strong export password.
5. Base64 encode the `.p12`:

   ```bash
   base64 -i DeveloperIDApplication.p12 -o DeveloperIDApplication.p12.base64
   ```

6. Save the base64 file contents as `APPLE_CERTIFICATE_P12_BASE64`.
7. Save the export password as `APPLE_CERTIFICATE_PASSWORD`.
8. Save the exact identity as `APPLE_SIGN_IDENTITY`.

To find the exact identity locally:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

## App Store Connect API Key

Create an App Store Connect API key that can be used for notarization and Mac App Store archive upload.

1. In App Store Connect, open **Users and Access > Integrations > App Store Connect API**.
2. Create or select an API key with access suitable for Developer ID notarization.
3. Download the private key file. Apple only allows downloading it once.
4. Save the key ID as `APPLE_ASC_KEY_ID`.
5. Save the issuer ID as `APPLE_ASC_ISSUER_ID`.
6. Save the full `.p8` file contents as `APPLE_ASC_API_KEY_P8`.

Paste the `.p8` contents exactly, including:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

## Release Workflow

This section covers the direct-download Developer ID DMG workflow. It is separate from the Mac App Store workflow.

The workflow runs for tags named `v*` and can also be retried manually from the GitHub Actions UI.

Normal release flow:

```bash
git switch main
git pull --ff-only
```

Update `pubspec.yaml`:

```yaml
version: 1.0.1+2
```

Run local checks:

```bash
flutter analyze
flutter test test/settings test/file_open_controller_test.dart test/file_open_channel_test.dart test/optimization
env RUSTC_WRAPPER= CARGO_BUILD_RUSTC_WRAPPER= cargo test --manifest-path rust/Cargo.toml
```

Commit and tag:

```bash
git add pubspec.yaml pubspec.lock
git commit -m "Bump version to 1.0.1"
git tag v1.0.1
git push origin main v1.0.1
```

The tag version must match the public version in `pubspec.yaml`. For example, `v1.0.1` matches `version: 1.0.1+2`.

## After the Workflow Finishes

The workflow creates a draft GitHub Release and attaches the DMG.

Before publishing the draft:

1. Download the DMG from the draft release.
2. Open the DMG.
3. Launch OIMG.
4. Confirm macOS does not show signing or notarization warnings.
5. Open an image and run a basic optimization.
6. Publish the GitHub Release when the DMG looks correct.

## Mac App Store Archive

The Developer ID DMG workflow is not a Mac App Store upload path. For App Store Connect, build an Xcode archive and export it with Mac App Store signing:

```bash
just archive-mas
```

The script writes outputs under `dist/macos-mas/`:

- `archive/` contains the `.xcarchive`.
- `export/` contains the exported App Store package or app output.
- `diagnostics/` contains codesign and entitlement dumps.

To upload through Xcode's App Store Connect export path:

```bash
just upload-mas
```

The MAS script uses Xcode automatic signing by default. If App Store Connect cloud-managed distribution certificates are unavailable, use manual signing with locally installed Mac App Store certificates and a matching provisioning profile.

Useful environment variables:

| Variable | Purpose |
| --- | --- |
| `APPLE_TEAM_ID` | Required Developer team ID passed to Xcode and export options. |
| `APPLE_MAS_SIGNING_STYLE` | `automatic` or `manual`; defaults to `automatic`. |
| `APPLE_MAS_APP_CERTIFICATE` | Manual signing app certificate selector or name, for example `3rd Party Mac Developer Application: ...`. |
| `APPLE_MAS_INSTALLER_CERTIFICATE` | Manual signing installer certificate selector or name, for example `3rd Party Mac Developer Installer: ...`. |
| `APPLE_MAS_PROFILE_NAME` | Manual signing provisioning profile name or UUID for the app bundle ID. |
| `APPLE_MAS_PROFILE_PATH` | Optional local `.provisionprofile` path; when set, the script installs it before archiving. |
| `APPLE_ASC_KEY_ID` | App Store Connect API key ID for provisioning/upload auth. |
| `APPLE_ASC_ISSUER_ID` | App Store Connect issuer ID. |
| `APPLE_ASC_API_KEY_PATH` | Path to `AuthKey_<key-id>.p8`; relative paths are resolved before calling Xcode. |
| `APPLE_ASC_API_KEY_P8` | Private key contents; the script writes a temporary key file. |

Manual signing example:

```bash
export APPLE_MAS_SIGNING_STYLE=manual
export APPLE_MAS_APP_CERTIFICATE="3rd Party Mac Developer Application: Your Name (ABCDE12345)"
export APPLE_MAS_INSTALLER_CERTIFICATE="3rd Party Mac Developer Installer: Your Name (ABCDE12345)"
export APPLE_MAS_PROFILE_NAME="OIMG MAS Profile"
export APPLE_MAS_PROFILE_PATH="/path/to/OIMG_MAS_Profile.provisionprofile"
```

Recommended first MAS validation:

1. Run `just archive-mas`.
2. Inspect `dist/macos-mas/diagnostics/archive-entitlements.plist`.
3. Confirm App Sandbox is present and `get-task-allow` is absent.
4. Inspect `dist/macos-mas/diagnostics/archive-codesign.txt`.
5. Confirm the archive is not ad-hoc signed and has the expected Team ID.
6. Install or run the exported build and repeat the sandbox/Finder Services tests.
7. Run `just upload-mas` only after the exported build looks correct.

## Notes

- The workflow pins `slimg` to commit `7e39c9353c2c0c493245a53ec7574e39b23a9ed4`, while `tjdistler-iqa-fork` uses `perf/simd-gaussian-vertical` and `irondash` uses `fix/macos-engine-context-race`.
- For more reproducible releases, later pin those sibling checkouts to tags or commit SHAs.
- The workflow uses GitHub-hosted `macos-14`; update that runner deliberately when changing Xcode/macOS build environments.
