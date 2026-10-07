# apple-sdk-extractor

Extract the **iOS / iPadOS / macOS / visionOS / watchOS / tvOS** SDKs bundled with Xcode on a GitHub-hosted macOS runner, package them, and download them for use elsewhere.

> Why this exists: some platform SDKs (visionOS / XROS in particular) are not available as standalone downloads from Apple, but they **ship inside Xcode, which is preinstalled on GitHub-hosted macOS runners**. This project does one thing only: it packages the SDKs that already exist on the runner. It does not bypass any download restriction.

## How it works

```
runs-on: xcode-27  (macOS 27 preview image, arm64)
        |  multiple Xcode versions preinstalled (published in actions/runner-images)
        v
/Applications/Xcode*.app/Contents/Developer/Platforms/<platform>.platform/Developer/SDKs/*.sdk
        v
pick Xcode version + pick platforms -> package as zip / tar.gz -> download from Actions artifacts
```

The Extract dropdowns are kept in sync by reading the **published metadata** for the target image from [actions/runner-images](https://github.com/actions/runner-images) (its Readme lists the installed Xcode versions and SDKs). That runs on a cheap Ubuntu job, so no macOS minutes are spent just to refresh the menu.

## Usage (just fork the repo)

1. Fork this repository.
2. Open the **Actions** tab.
3. The **Extract Apple SDKs** dropdowns are populated automatically. The **List available Apple SDKs** workflow runs on a cheap Ubuntu runner, reads the published metadata for the target image from `actions/runner-images`, and rewrites the Extract dropdowns to match. It runs on every push and weekly, and can also be run manually.
4. Run **Extract Apple SDKs** with the inputs you want:
   - **xcode**: dropdown, `latest` plus every installed Xcode.
   - **platforms**: dropdown, `all` plus every platform combination.
   - **include_simulators**: also package the simulator SDKs.
   - **package**: `zip` or `tar.gz`.
   - **dereference_symlinks**: resolve symlinks into real files (self-contained, but much larger).
   - **upload_artifact**: upload to Actions artifacts (on by default).
   - **upload_to_release**: also publish to a GitHub Release.
5. When the run finishes, download the archives from the **Artifacts** section of the run.

### Where the archives go

By default the archives are uploaded as **Actions artifacts**, downloaded from the run page. Extract artifacts are kept for 7 days. Free plans have an artifact storage quota (about 500 MB), which a full `all` + simulators selection can exceed, so **upload_to_release** is available for permanent storage and for very large multi-GB sets.

## The two workflows

| File | Purpose | Trigger |
| --- | --- | --- |
| `.github/workflows/list-apple-sdks.yml` | Read the target image's metadata from `actions/runner-images` and regenerate the Extract dropdowns | Automatic (push, weekly, manual) |
| `.github/workflows/extract-apple-sdks.yml` | Extract and package the selected SDKs, upload to Artifact / Release | Manual |

`extract-apple-sdks.yml` keeps its workflow logic by hand; only the two blocks between the `# GENERATED:...` markers are rewritten by the List workflow. Edit the workflow directly for logic changes, and `.github/scripts/lib.sh` for the platform/version mapping.

### Target image

Both workflows target the **macOS 27 public preview** image, whose YAML label is **`xcode-27`** (arm64). There is no `macos-27` label. To use a different image, change the `runs-on:` line in `.github/workflows/extract-apple-sdks.yml` (for example `macos-latest` or `macos-15`); the next **List available Apple SDKs** run regenerates the dropdowns to match that image's Xcode versions.

### Enabling automatic menu updates (optional)

GitHub does not allow the default `GITHUB_TOKEN` to update files under `.github/workflows/`; it requires a token with the `workflow` scope. So, out of the box, the List workflow regenerates the menu but can only **upload it as an artifact** (the job still succeeds with a warning). The committed menu is whatever the upstream repo last generated, which is fine for most forks.

To have each fork update its own menu automatically, add a repository secret **`SDK_EXTRACTOR_TOKEN`** containing a Personal Access Token (classic) with the `repo` and `workflow` scopes. The List workflow then commits the refreshed workflow on every run.

> A pull request instead of a direct commit would hit the same wall: pushing a branch that changes a workflow file is rejected for the same reason. Dependabot can do it because it is a separate GitHub App with its own permissions, not the Actions `GITHUB_TOKEN`.

The logic lives in `.github/scripts/` and can also be run locally:

```bash
# Regenerate the Extract dropdowns (any OS with bash + curl). Reads the target
# image from the workflow's runs-on; override with TARGET_RUNNER=macos-26.
bash .github/scripts/render-extract-workflow.sh

# Enumerate the Xcode versions and SDKs of a real Mac (macOS only).
bash .github/scripts/list-sdks.sh

# Extract and package SDKs (macOS only).
XCODE_INPUT=latest PLATFORMS=visionos,ios INCLUDE_SIMULATORS=false \
  OUTDIR=./out bash .github/scripts/extract-sdks.sh
```

## Option to platform mapping

| Platform | Input value | Path inside Xcode |
| --- | --- | --- |
| iOS / iPadOS | `ios` | `iPhoneOS.platform` |
| iOS Simulator | `ios` + `include_simulators` | `iPhoneSimulator.platform` |
| macOS | `macos` | `MacOSX.platform` |
| visionOS | `visionos` | `XROS.platform` |
| visionOS Simulator | `visionos` + `include_simulators` | `XRSimulator.platform` |
| watchOS | `watchos` | `WatchOS.platform` |
| tvOS | `tvos` | `AppleTVOS.platform` |

Xcode also ships versioned SDK symlink aliases (for example `iPhoneOS26.0.sdk` pointing at the real `iPhoneOS.sdk`). These are skipped so each SDK is packaged exactly once.

## Notes

- The default target, `xcode-27`, is a **public preview** image and may change or be renamed. If a run fails to schedule, point `runs-on:` at a stable label such as `macos-latest` or `macos-15`.
- Extracted SDKs may contain symlinks that point into Xcode's internal paths. `zip` (created with `ditto`) preserves the links. If you need to use the SDK on a machine without Xcode, enable `dereference_symlinks`.
- Large platforms (macOS, visionOS) are big; mind your fork's Actions storage and minutes (macOS runners are billed at a multiplier).
- This repository does not distribute any Apple software. It only provides tooling that extracts files already present in your own run environment (the GitHub runner).

## License

MIT, see [LICENSE](LICENSE).
