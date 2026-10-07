#!/usr/bin/env bash
#
# apple-sdk-extractor / list-sdks.sh
#
# Print every Xcode installation found on the runner together with the SDKs
# bundled inside it. Output is Markdown so it can be dropped straight into a
# GitHub Actions job summary.
#
set -euo pipefail
export COPYFILE_DISABLE=1

# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

human_size() {
  du -sh "$1" 2>/dev/null | cut -f1
}

printf '## Available Apple SDKs on `%s`\n\n' "${ImageOS:-macos}${ImageVersion:+ $ImageVersion}"
printf 'Default Xcode: `%s`\n\n' "$(xcode-select -p 2>/dev/null || echo n/a)"

printf '| Xcode | Xcode version | SDK bundle | Platform | Kind | Size | Version |\n'
printf '| --- | --- | --- | --- | --- | --- | --- |\n'

found=0
aliases=0
for app in $(xcode_apps); do
  [ -d "$app" ] || continue
  ver="$(xcode_version_of "$app")"
  for sdk in "$app"/Contents/Developer/Platforms/*.platform/Developer/SDKs/*.sdk; do
    [ -d "$sdk" ] || continue
    if [ -L "$sdk" ]; then aliases=$((aliases + 1)); continue; fi
    platdir="$(dirname "$(dirname "$(dirname "$sdk")")")"
    plat="$(basename "$platdir")"
    kind="device"; case "$plat" in *Simulator.platform) kind="simulator" ;; esac
    sdkver="$(/usr/libexec/PlistBuddy -c 'Print Version' "$sdk/SDKSettings.plist" 2>/dev/null || printf '?')"
    printf '| `%s` | %s | `%s` | %s | %s | %s | %s |\n' \
      "$(basename "$app")" "$ver" "$(basename "$sdk")" "$plat" "$kind" "$(human_size "$sdk")" "$sdkver"
    found=$((found + 1))
  done
done

if [ "$found" -eq 0 ]; then
  printf '\n_No Xcode installations or SDKs were found._\n'
fi

if [ "$aliases" -gt 0 ]; then
  printf '\n_%s versioned SDK alias(es) (symlinks such as `iPhoneOS26.0.sdk`) were hidden; only real SDK directories are listed._\n' "$aliases"
fi

printf '\nUse the **Extract Apple SDKs** workflow with the Xcode name/version and the platforms above.\n'
