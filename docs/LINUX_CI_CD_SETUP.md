# Linux Debian CI/CD Setup

One-time setup and operating notes for the GitHub Linux Debian release workflow.

## GitHub Secrets

Add this secret in GitHub under **Settings > Secrets and variables > Actions > Repository secrets**.

| Secret | Purpose |
| --- | --- |
| `CI_REPO_TOKEN` | GitHub token with read access to `yunho-c/slimg`, `yunho-c/tjdistler-iqa-fork`, and `yunho-c/irondash`. |

## GitHub Token

Create a fine-grained personal access token that can read the sibling repositories:

- `yunho-c/slimg`
- `yunho-c/tjdistler-iqa-fork`
- `yunho-c/irondash`

Give it read-only repository contents access, then save it as `CI_REPO_TOKEN`.

## Release Workflow

The workflow runs for tags named `v*` and can also be retried manually from the GitHub Actions UI.

The Linux workflow uses GitHub-hosted `ubuntu-24.04` and produces an unsigned `amd64` `.deb`.

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

## Package Contents

The `.deb` should include:

- `/opt/oimg/oimg`
- `/opt/oimg/oimg-service`
- `/usr/share/applications/oimg.desktop`
- `/usr/share/icons/oimg.png`
- `/usr/share/nautilus-python/extensions/oimg.py`

The package should depend on `python3-nautilus` so Nautilus can load the context-menu extension.

## After the Workflow Finishes

The workflow creates or reuses a draft GitHub Release and attaches the `.deb`.

Before publishing the draft:

1. Download the `.deb` from the draft release.
2. Install it on an `amd64` Debian/Ubuntu/Pop!_OS machine:

   ```bash
   sudo dpkg -i oimg_*_amd64.deb
   sudo apt install -f
   ```

3. Launch OIMG.
4. Confirm Open With registration:

   ```bash
   gio mime image/png
   gio mime image/avif
   ```

5. If testing Nautilus actions, restart Files:

   ```bash
   nautilus -q
   ```

6. Right-click a supported image and verify:
   - `Compress image`
   - `Compress image (lossless)`
7. Publish the GitHub Release when the package looks correct.

## Notes

- The package is not GPG-signed and is not an apt repository artifact yet.
- The workflow pins `slimg` to commit `7e39c9353c2c0c493245a53ec7574e39b23a9ed4`, while `tjdistler-iqa-fork` uses `perf/simd-gaussian-vertical` and `irondash` uses `fix/macos-engine-context-race`.
- For more reproducible releases, later pin those sibling checkouts to tags or commit SHAs.
- For `arm64` Linux releases, add a native ARM runner or a dedicated cross-build workflow instead of relying on the current `ubuntu-24.04` hosted runner.
