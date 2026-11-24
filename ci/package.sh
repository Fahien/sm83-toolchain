#!/usr/bin/env bash
# Packs one package of one host into out/dist and prints its dependency.
#
# Usage: bash ci/package.sh <package> <host> <download URL of the release>
#
# Reads out/<host>/<package>, as `zig build -Dhost=<host> --prefix out/<host>`
# installs it. Writes out/dist/<package>-<host>.tar.xz and
# out/dist/<package>-<host>.zon.
set -euo pipefail

package=$1
host=$2
url_base=$3
dist=out/dist
name=$package-$host.tar.xz

mkdir -p "$dist"

# The package's entries sit at the tarball root. Zig strips a single
# top-level directory, and a plain `zig fetch` then caches a copy that
# later fails with "hash mismatch". COPYFILE_DISABLE keeps macOS tar
# from adding ._ files.
(cd "out/$host/$package" && COPYFILE_DISABLE=1 tar -cf - *) | xz -9 -T0 > "$dist/$name"

hash=$(zig fetch "$PWD/$dist/$name")
dependency=$(echo "$package" | tr - _)_$host
printf '.%s = .{\n    .url = "%s/%s",\n    .hash = "%s",\n    .lazy = true,\n},\n' \
    "$dependency" "$url_base" "$name" "$hash" | tee "$dist/$package-$host.zon"
