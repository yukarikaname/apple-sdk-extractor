#!/usr/bin/env bash
#
# apple-sdk-extractor / extract-sdks.sh
#
# Extract the Apple platform SDKs that ship inside Xcode on a GitHub-hosted
# macOS runner, package them into archives, and (optionally) upload them.
#
# Configuration is read from the environment so the same script works locally
# and inside GitHub Actions:
#
#   XCODE_INPUT         "latest" (default) or an Xcode version / app name,
#                       e.g. "16.1", "Xcode_16.1.app", "/Applications/Xcode.app"
#   PLATFORMS           comma separated list: macos,ios,visionos,watchos,tvos
#                       or "all" (default)
#   INCLUDE_SIMULATORS  "true" / "false" (default: false)
#   PACKAGE             "zip" (default) or "tar.gz"
#   DEREFERENCE         "true" / "false" follow symlinks (default: false)
#   OUTDIR              output directory (default: ./apple-sdks)
#
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Keep macOS from polluting archives with AppleDouble (._*) files.
export COPYFILE_DISABLE=1

XCODE_INPUT="${XCODE_INPUT:-latest}"
PLATFORMS="${PLATFORMS:-all}"
INCLUDE_SIMULATORS="${INCLUDE_SIMULATORS:-false}"
PACKAGE="${PACKAGE:-zip}"
DEREFERENCE="${DEREFERENCE:-false}"
OUTDIR="${OUTDIR:-$PWD/apple-sdks}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Print the path of the Xcode to use.
resolve_xcode() {
  local input="$1" app candidate match
  if [ -z "$input" ] || [ "$input" = "latest" ]; then
    # Prefer the runner's default Xcode (the Xcode.app symlink, which is what
    # xcode-select points at) so "latest" never silently picks a beta.
    if [ -d "/Applications/Xcode.app" ]; then
      printf '%s\n' "/Applications/Xcode.app"
    else
      xcode_apps_newest_first | head -n1 | cut -f2-
    fi
    return 0
  fi
  for candidate in "$input" "/Applications/$input" \
                   "/Applications/Xcode_$input.app" "/Applications/Xcode$input.app"; do
    if [ -d "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  match="$(ls -d /Applications/*"$input"*.app 2>/dev/null | head -n1 || true)"
  if [ -n "$match" ]; then printf '%s\n' "$match"; return 0; fi
  die "No Xcode matching '$input' found in /Applications"
}

# True when the family/kind passes the PLATFORMS / INCLUDE_SIMULATORS filter.
is_selected() {
  local key="$1" kind="$2" p
  if [ "$kind" = "simulator" ] && [ "$INCLUDE_SIMULATORS" != "true" ]; then
    return 1
  fi
  for p in $PLATFORMS_LOWER; do
    if [ "$p" = "all" ] || [ "$p" = "$key" ]; then return 0; fi
  done
  return 1
}

# $1 = .sdk directory, $2 = output archive path
package_sdk() {
  local sdk="$1" out="$2" parent name tmp
  if [ "$PACKAGE" = "zip" ]; then
    if [ "$DEREFERENCE" = "true" ]; then
      tmp="$(mktemp -d)"
      rsync -a --copy-links "$sdk" "$tmp/"
      ditto -c -k --sequesterRsrc --keepParent "$tmp/$(basename "$sdk")" "$out"
      rm -rf "$tmp"
    else
      # ditto preserves symlinks, extended attributes and resource forks.
      ditto -c -k --sequesterRsrc --keepParent "$sdk" "$out"
    fi
  else
    parent="$(dirname "$sdk")"
    name="$(basename "$sdk")"
    if [ "$DEREFERENCE" = "true" ]; then
      tar -czhf "$out" -C "$parent" "$name"
    else
      tar -czf "$out" -C "$parent" "$name"
    fi
  fi
}

# ---------------------------------------------------------------------------
log 'Xcode.app found in /Applications:'
for app in /Applications/Xcode*.app; do
  [ -d "$app" ] && printf '    %-46s %s\n' "$(basename "$app")" "$(xcode_version_of "$app")"
done

XCODE_APP="$(resolve_xcode "$XCODE_INPUT")"
if [ -z "$XCODE_APP" ] || [ ! -d "$XCODE_APP" ]; then
  die "Could not resolve an Xcode for '$XCODE_INPUT'"
fi
XCODE_VER="$(xcode_version_of "$XCODE_APP")"
log "Selected Xcode: $XCODE_APP (version $XCODE_VER)"

if command -v sudo >/dev/null 2>&1; then
  sudo xcode-select -s "$XCODE_APP" || warn 'xcode-select failed (continuing)'
fi
xcodebuild -version || true

PLATFORMS_LOWER="$(printf '%s' "$PLATFORMS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')"
PLATFORMS_DIR="$XCODE_APP/Contents/Developer/Platforms"
[ -d "$PLATFORMS_DIR" ] || die "Platforms directory not found: $PLATFORMS_DIR"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.zip "$OUTDIR"/*.tar.gz "$OUTDIR"/SHA256SUMS.txt "$OUTDIR"/manifest.txt 2>/dev/null || true

MANIFEST="$OUTDIR/manifest.txt"
{
  printf 'project: apple-sdk-extractor\n'
  printf 'xcode: %s\n' "$XCODE_APP"
  printf 'xcode_version: %s\n' "$XCODE_VER"
  printf 'package: %s\n' "$PACKAGE"
  printf 'dereferenced: %s\n' "$DEREFERENCE"
  printf 'platforms: %s\n' "$PLATFORMS"
  printf 'include_simulators: %s\n' "$INCLUDE_SIMULATORS"
  printf 'generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MANIFEST"

count=0
for sdk in "$PLATFORMS_DIR"/*.platform/Developer/SDKs/*.sdk; do
  [ -d "$sdk" ] || continue
  # Xcode ships unversioned SDKs (iPhoneOS.sdk) plus versioned aliases
  # (iPhoneOS26.0.sdk) that are symlinks to the real directory. Package only
  # the real one so we neither duplicate data nor collide on output names.
  if [ -L "$sdk" ]; then
    log "Skip symlinked alias: $(basename "$sdk")"
    continue
  fi
  platdir="$(dirname "$(dirname "$(dirname "$sdk")")")"
  platname="$(basename "$platdir")"
  key="$(platform_key "$platname")"
  if [ -z "$key" ]; then
    log "Skip unsupported platform: $platname"
    continue
  fi
  kind="$(platform_kind "$platname")"
  if ! is_selected "$key" "$kind"; then
    log "Skip $key/$kind  ($(basename "$sdk"))"
    continue
  fi

  ver="$(/usr/libexec/PlistBuddy -c 'Print Version' "$sdk/SDKSettings.plist" 2>/dev/null || true)"
  if [ -z "$ver" ]; then
    ver="$(basename "$sdk" .sdk | sed -E 's/^[^0-9]*//')"
  fi
  [ -n "$ver" ] || ver="unknown"

  ext="zip"; [ "$PACKAGE" = "zip" ] || ext="tar.gz"
  base="${key}-${ver}-${kind}"
  out="$OUTDIR/${base}.${ext}"

  log "Packaging ${base}.${ext}  <-  $sdk"
  package_sdk "$sdk" "$out"

  size="$(du -h "$out" | cut -f1)"
  printf '%-32s %8s  %s\n' "${base}.${ext}" "$size" "$(basename "$sdk")" >> "$MANIFEST"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  die "No SDK matched the selection (platforms='$PLATFORMS', simulators='$INCLUDE_SIMULATORS')."
fi

log 'Generating SHA256SUMS.txt'
( cd "$OUTDIR" && shasum -a 256 *.zip *.tar.gz 2>/dev/null > SHA256SUMS.txt || true )

log "Created $count archive(s) in $OUTDIR"
ls -lh "$OUTDIR"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'xcode_version=%s\n' "$XCODE_VER"
    printf 'xcode_name=%s\n' "$(basename "$XCODE_APP")"
    printf 'outdir=%s\n' "$OUTDIR"
    printf 'count=%s\n' "$count"
  } >> "$GITHUB_OUTPUT"
fi
