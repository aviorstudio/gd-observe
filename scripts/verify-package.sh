#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-$root/dist/@aviorstudio_gd-observe.zip}"
manifest="$root/gd/package-manifest.txt"

test -f "$archive"
python3 - "$archive" "$manifest" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
expected = pathlib.Path(sys.argv[2]).read_text().splitlines()
with zipfile.ZipFile(archive) as package:
    infos = package.infolist()
    names = [entry.filename.rstrip("/") for entry in infos if not entry.is_dir()]
    if names != expected:
        raise SystemExit(f"closed manifest mismatch\nexpected={expected!r}\nactual={names!r}")
    for entry in infos:
        path = pathlib.PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {entry.filename}")
        mode = entry.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise SystemExit(f"archive symlink rejected: {entry.filename}")
print(f"PASS closed package manifest ({len(expected)} files)")
PY
sha256sum "$archive"
