#!/usr/bin/env bash
set -euo pipefail

version="4.7.2-stable"
archive_name="Godot_v${version}_linux.x86_64.zip"
sha256="cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4"
install_root="${1:-${RUNNER_TEMP:-/tmp}/gd-observe-godot}"
archive="$install_root/$archive_name"
binary="$install_root/Godot_v${version}_linux.x86_64"

mkdir -p "$install_root"
curl --fail --location --retry 3 --max-time 180 \
  "https://github.com/godotengine/godot/releases/download/${version}/${archive_name}" \
  --output "$archive"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check
unzip -oq "$archive" -d "$install_root"
chmod +x "$binary"
"$binary" --version
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'GODOT_BIN=%s\n' "$binary" >> "$GITHUB_ENV"
fi
printf '%s\n' "$binary"
