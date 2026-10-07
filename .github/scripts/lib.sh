#!/usr/bin/env bash
#
# apple-sdk-extractor / lib.sh
#
# Shared helpers. Source this file, do not execute it directly.
#

# Version string of an Xcode.app (CFBundleShortVersionString).
xcode_version_of() {
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$1/Contents/version.plist" 2>/dev/null || printf '0'
}

# Every Xcode.app path, one per line.
xcode_apps() {
  local app
  for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    printf '%s\n' "$app"
  done
}

# "version<TAB>path" for every Xcode, newest first.
xcode_apps_newest_first() {
  xcode_apps | while IFS= read -r app; do
    printf '%s\t%s\n' "$(xcode_version_of "$app")" "$app"
  done | sort -V -r
}

# Map a *.platform directory name to a short family name.
platform_key() {
  case "$1" in
    iPhoneOS.platform|iPhoneSimulator.platform)   printf 'ios' ;;
    AppleTVOS.platform|AppleTVSimulator.platform) printf 'tvos' ;;
    WatchOS.platform|WatchSimulator.platform)     printf 'watchos' ;;
    XROS.platform|XRSimulator.platform)           printf 'visionos' ;;
    MacOSX.platform)                              printf 'macos' ;;
    *)                                            printf '' ;;
  esac
}

# device / simulator for a *.platform directory name.
platform_kind() {
  case "$1" in
    *Simulator.platform) printf 'simulator' ;;
    *)                   printf 'device' ;;
  esac
}

# Distinct family names available in the given Xcode, space separated,
# in a stable order.
available_families() {
  local xcode="$1" platdir fams=""
  for platdir in "$xcode"/Contents/Developer/Platforms/*.platform; do
    [ -d "$platdir" ] || continue
    local k
    k="$(platform_key "$(basename "$platdir")")"
    [ -n "$k" ] || continue
    case " $fams " in
      *" $k "*) ;;
      *) fams="$fams $k" ;;
    esac
  done
  printf '%s' "${fams# }"
}

# Print every non-empty subset of the given families, largest first, as
# comma separated values. $@ = family names. Excludes the full set.
subsets_desc() {
  local n total size mask m bits idx fam out
  set -- $*
  n=$#
  [ "$n" -ge 1 ] || return 0
  total=$((1 << n))
  size=$((n - 1))
  while [ "$size" -ge 1 ]; do
    mask=1
    while [ "$mask" -lt "$total" ]; do
      m=$mask; bits=0
      while [ "$m" -ne 0 ]; do
        [ $((m & 1)) -ne 0 ] && bits=$((bits + 1))
        m=$((m >> 1))
      done
      if [ "$bits" -eq "$size" ]; then
        m=$mask; idx=0; out=""
        while [ "$m" -ne 0 ]; do
          if [ $((m & 1)) -ne 0 ]; then
            eval "fam=\${$((idx + 1))}"
            [ -n "$out" ] && out="$out,$fam" || out="$fam"
          fi
          m=$((m >> 1)); idx=$((idx + 1))
        done
        printf '%s\n' "$out"
      fi
      mask=$((mask + 1))
    done
    size=$((size - 1))
  done
}

# Replace the lines between the "GENERATED:<name>:start" and
# "GENERATED:<name>:end" markers in workflow file $1 with the contents of the
# file named by $3. Safe on macOS/BSD and Linux. $2 = block name (xcode/platforms).
replace_generated_block() {
  local wf="$1" name="$2" content="$3" out started=0 line
  out="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"GENERATED:${name}:start"*) printf '%s\n' "$line"; cat "$content"; started=1; continue ;;
      *"GENERATED:${name}:end"*)   printf '%s\n' "$line"; started=0; continue ;;
    esac
    if [ "$started" -eq 0 ]; then printf '%s\n' "$line"; fi
  done < "$wf" > "$out"
  mv "$out" "$wf"
}
