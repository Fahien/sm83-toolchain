#!/usr/bin/env bash
# Unpacks the two tarballs of one host and compiles a Zig function to SM83 assembly.
#
# Usage: bash ci/smoke.sh <directory with the tarballs> <host>
set -euo pipefail

dist=$1
host=$2
work=$(mktemp -d "${TMPDIR:-/tmp}/sm83-smoke.XXXXXX")

mkdir "$work/llvm-sm83" "$work/zig-sm83"
tar -xJf "$dist/llvm-sm83-$host.tar.xz" -C "$work/llvm-sm83"
tar -xJf "$dist/zig-sm83-$host.tar.xz" -C "$work/zig-sm83"

cat > "$work/smoke.zig" <<'ZIG'
export fn add(a: u8, b: u8) u8 {
    return a +% b;
}
ZIG

"$work/zig-sm83/bin/zig" build-obj -target sm83-freestanding -O ReleaseFast \
    -fstrip -fllvm -fno-emit-bin \
    --zig-lib-dir "$work/zig-sm83/lib" \
    --cache-dir "$work/cache" --global-cache-dir "$work/global-cache" \
    --verbose-llvm-ir="$work/smoke.ll" "$work/smoke.zig"
"$work/llvm-sm83/bin/opt" -S -passes=globaldce "$work/smoke.ll" -o "$work/smoke.opt.ll"
"$work/llvm-sm83/bin/llc" -O1 -verify-machineinstrs -mtriple=sm83-unknown-none-sdcc \
    -z80-asm-format=sdasz80 -filetype=asm "$work/smoke.opt.ll" -o "$work/smoke.asm"

# The export names the stripped function, and its body is one SM83 add.
grep '^_add = L_smoke.add$' "$work/smoke.asm"
grep -q $'^\tadd\ta,e$' "$work/smoke.asm"
rm -rf "$work"
