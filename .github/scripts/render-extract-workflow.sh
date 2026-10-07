#!/usr/bin/env bash
#
# apple-sdk-extractor / render-extract-workflow.sh
#
# Refresh the workflow_dispatch dropdowns in .github/workflows/extract-apple-sdks.yml
# so they match the macOS runner image the Extract job targets.
#
# GitHub does not support dynamic workflow_dispatch inputs, so the only way to
# get dropdowns that update themselves is to rewrite part of the workflow file
# and commit it.
#
# Rather than spending macOS runner minutes to enumerate a live machine, this
# reads the published metadata for the target image from
# https://github.com/actions/runner-images (the image Readme lists the installed
# Xcode versions and SDKs). The image is taken from the `runs-on:` value of the
# Extract workflow, so there is a single source of truth.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows/extract-apple-sdks.yml"

[ -f "$WF" ] || { echo "Workflow not found: $WF" >&2; exit 1; }
grep -q 'GENERATED:xcode:start' "$WF"     || { echo "Missing GENERATED:xcode marker in $WF" >&2; exit 1; }
grep -q 'GENERATED:platforms:start' "$WF" || { echo "Missing GENERATED:platforms marker in $WF" >&2; exit 1; }

# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- Which runner image are we describing? -----------------------------------
TARGET_RUNNER="${TARGET_RUNNER:-$(sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p' "$WF" | head -n1 | tr -d "'\"")}"
[ -n "$TARGET_RUNNER" ] || TARGET_RUNNER='xcode-27'

runner_readme_name() {
  case "$1" in
    xcode-27|xcode-27-xlarge)                     echo 'xcode-27-arm64-Readme.md' ;;
    macos-latest|macos-26|macos-26-xlarge)        echo 'macos-26-arm64-Readme.md' ;;
    macos-latest-large|macos-26-large|macos-26-intel) echo 'macos-26-Readme.md' ;;
    macos-15|macos-15-xlarge)                     echo 'macos-15-arm64-Readme.md' ;;
    macos-15-large|macos-15-intel)                echo 'macos-15-Readme.md' ;;
    macos-14|macos-14-xlarge)                     echo 'macos-14-arm64-Readme.md' ;;
    macos-14-large|macos-14-intel)                echo 'macos-14-Readme.md' ;;
    *)                                            echo "$1-arm64-Readme.md" ;;
  esac
}

readme_name="$(runner_readme_name "$TARGET_RUNNER")"
readme_url="https://raw.githubusercontent.com/actions/runner-images/main/images/macos/$readme_name"

readme="$(mktemp)"
xcode_opts="$(mktemp)"
platform_opts="$(mktemp)"
trap 'rm -f "$readme" "$xcode_opts" "$platform_opts"' EXIT

if ! curl -fsSL "$readme_url" -o "$readme"; then
  echo "Could not fetch runner image metadata: $readme_url" >&2
  exit 1
fi

# --- Xcode choices: "latest" plus every Xcode path in the image --------------
# The Xcode table lists the canonical Path first and any symlinks after it, and
# is ordered newest first. Extract every /Applications/Xcode*.app name.
{
  printf '          - latest\n'
  sed -n '/^### Xcode/,/^#### /p' "$readme" \
    | grep -oE '/Applications/[^ |<]+\.app' \
    | sed 's#.*/##' \
    | awk '!seen[$0]++' \
    | while IFS= read -r app; do printf '          - %s\n' "$app"; done
} > "$xcode_opts"

# --- Platform choices: "all" plus every proper subset of the families --------
families=""
while IFS= read -r sdkname; do
  [ -n "$sdkname" ] || continue
  case "$sdkname" in
    macosx*)                     k='macos' ;;
    iphoneos*|iphonesimulator*)  k='ios' ;;
    appletvos*|appletvsimulator*) k='tvos' ;;
    watchos*|watchsimulator*)    k='watchos' ;;
    xros*|xrsimulator*)          k='visionos' ;;
    *)                           continue ;;
  esac
  case " $families " in
    *" $k "*) ;;
    *) families="$families $k" ;;
  esac
done <<EOF
$(sed -n '/^#### Installed SDKs/,/^#### /p' "$readme" | awk -F'|' 'NF >= 3 { gsub(/ /, "", $3); print $3 }')
EOF
families="${families# }"

{
  printf '          - all\n'
  if [ -n "$families" ]; then
    # shellcheck disable=SC2086
    subsets_desc $families | sed 's/^/          - /'
  fi
} > "$platform_opts"

# --- Sanity check: every option line must be a properly indented list item ---
for f in "$xcode_opts" "$platform_opts"; do
  if grep -qv '^          - ' "$f"; then
    echo "Refusing to write malformed options (bad line in $f):" >&2
    grep -nv '^          - ' "$f" >&2
    exit 1
  fi
done

# --- Replace the marked blocks in place --------------------------------------
replace_generated_block "$WF" xcode     "$xcode_opts"
replace_generated_block "$WF" platforms "$platform_opts"

echo "Updated $WF from ${readme_url}"
echo
echo "### Runner image \`${TARGET_RUNNER}\`"
echo
echo "Source: [\`actions/runner-images/${readme_name}\`](https://github.com/actions/runner-images/blob/main/images/macos/${readme_name})"
echo
sed -n '/^### Xcode/,/^#### Installed SDKs/p' "$readme" | sed '$d'
sed -n '/^#### Installed SDKs/,/^#### /p' "$readme"
