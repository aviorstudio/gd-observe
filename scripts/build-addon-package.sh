#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/gd/addon"
manifest="$root/gd/package-manifest.txt"
output="${1:-$root/dist/@aviorstudio_gd-observe.zip}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

test -f "$manifest"
if [ -n "$(find "$source_dir" -type l -print -quit)" ]; then
  echo "Package source contains a symlink" >&2
  exit 1
fi

actual="$stage/actual.txt"
(cd "$source_dir" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$actual"
if ! diff -u "$manifest" "$actual"; then
  echo "Package contents differ from gd/package-manifest.txt" >&2
  exit 1
fi

package_root="$stage/package"
mkdir -p "$package_root" "$(dirname "$output")"
while IFS= read -r path; do
  case "$path" in
    ""|/*|*".."*) echo "Unsafe package path: $path" >&2; exit 1 ;;
  esac
  mkdir -p "$package_root/$(dirname "$path")"
  cp "$source_dir/$path" "$package_root/$path"
done < "$manifest"

rm -f "$output"
(cd "$package_root" && zip -X -q "$output" -@ < "$manifest")
sha256sum "$output"
