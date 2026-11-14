#!/usr/bin/env bash
# Packs the two packages of one host into out/dist and prints their dependencies.
#
# Usage: bash ci/package.sh <host> <download URL of the release>
#
# Reads out/<host>/llvm-sm83 and out/<host>/zig-sm83, as `zig build -Dhost=<host>
# --prefix out/<host>` installs them. Writes out/dist/<package>-<host>.tar.xz and
# out/dist/<host>.zon.
set -euo pipefail

host=$1
url_base=$2
dist=out/dist

mkdir -p "$dist"
: > "$dist/$host.zon"

for package in llvm-sm83 zig-sm83; do
    name=$package-$host.tar.xz

    # The package's entries sit at the tarball root. Zig strips a single
    # top-level directory, and a plain `zig fetch` then caches a copy that
    # later fails with "hash mismatch". COPYFILE_DISABLE keeps macOS tar
    # from adding ._ files.
    (cd "out/$host/$package" && COPYFILE_DISABLE=1 tar -cf - *) | xz -9 -T0 > "$dist/$name"

    hash=$(zig fetch "$PWD/$dist/$name")
    dependency=$(echo "$package" | tr - _)_$host
    printf '.%s = .{\n    .url = "%s/%s",\n    .hash = "%s",\n    .lazy = true,\n},\n' \
        "$dependency" "$url_base" "$name" "$hash" >> "$dist/$host.zon"
done

cat "$dist/$host.zon"
