# sm83-toolchain

Toolchain to build Game Boy ROMs from Zig.

| Package | Files | Source |
| --- | --- | --- |
| `llvm-sm83-<host>.tar.xz` | `bin/llc`, `bin/opt`, `lib/sm83/*.asm`, `LICENSE.TXT` | [llvm-z80](https://github.com/llvm-z80/llvm-z80) |
| `zig-sm83-<host>.tar.xz` | `bin/zig`, `lib/std/`, `LICENSE` | [zig-z80](https://github.com/llvm-z80/zig-z80) |

`<host>` is `macos_aarch64` or `linux_x86_64`. `build.zig.zon` pins the source commits.

## Build

```sh
zig build -Dhost=<host> --prefix out/<host>
```

`-Dpackage=llvm-sm83` or `-Dpackage=zig-sm83` builds one package and fetches only its source.

The build needs `cmake`, `ninja` and Zig 0.17.1 on `PATH`. `zig cc` compiles LLVM for the host, so a Mac builds both hosts. The macOS packages build only on a Mac.

- The Linux `llc` and `opt` link glibc 2.28 and libc++ statically.
- The Linux `zig` links musl statically.
- Every binary targets the baseline CPU of its architecture.

## CI release

The `release` workflow does four things:

1. Builds each package of each host on its own runner.
2. Packs the files with `ci/package.sh`.
3. Compiles test functions on each host with `ci/smoke.sh`, using the unpacked tarballs.
4. Publishes a release whose tag is the first 12 characters of the commit.

## Use from your zig project

Pin one package per host and per tool, as lazy dependencies:

```zig
.llvm_sm83_macos_aarch64 = .{
    .url = "https://github.com/Fahien/sm83-toolchain/releases/download/<tag>/llvm-sm83-macos_aarch64.tar.xz",
    .hash = "...",
    .lazy = true,
},
```

## License

The files of this repository are licensed under either of these, at your option:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

Unless you explicitly state otherwise, any contribution that you intentionally submit for inclusion in this work, as defined in the Apache-2.0 license, is dual licensed as above, without any additional terms or conditions.

The packages hold binaries built from other projects, and each package carries its source's license:

- `llvm-sm83` is under the Apache License v2.0 with LLVM Exceptions, in `LICENSE.TXT`. The runtime helpers in `lib/sm83` are under their own licenses, in `lib/sm83/LICENSE`.
- `zig-sm83` is under the MIT license, in `LICENSE`.
