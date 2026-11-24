//! Builds the SM83 toolchain.
//!
//! `zig build -Dhost=<host>` installs two directories. Each one holds
//! the files of one package:
//!
//! ```
//! zig-out/llvm-sm83/   bin/llc, bin/opt, lib/sm83/*.asm, LICENSE.TXT
//! zig-out/zig-sm83/    bin/zig, lib/std/, LICENSE
//! ```
//!
//! `-Dpackage=<package>` installs only one of them.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const host = b.option(Host, "host", "Host that the toolchain runs on (default: this machine)") orelse Host.native(b);
    if (host == .macos_aarch64 and Host.native(b) != .macos_aarch64) {
        @panic("The macOS packages build only on a Mac");
    }

    const package = b.option(Package, "package", "Package to build (default: both)");

    // The sources are lazy, so a build of one package fetches only its source.
    if (package == null or package == .@"llvm-sm83") {
        const llvm_z80 = try b.dependencyLazy("llvm_z80", .{});
        installLlvm(b, llvm_z80, Tablegen.build(b, llvm_z80), host);
    }
    if (package == null or package == .@"zig-sm83") {
        const zig_sm83 = try b.dependencyLazy("zig_sm83", .{ .@"version-string" = "0.17.0" });
        installZig(b, zig_sm83, host);
    }
}

/// Each field is the name of the package's install directory.
const Package = enum { @"llvm-sm83", @"zig-sm83" };

/// A machine that builds ROMs. Each host gets its own pair of packages.
const Host = enum {
    macos_aarch64,
    linux_x86_64,

    fn native(b: *std.Build) Host {
        const target = b.graph.host.result;
        if (target.os.tag == .macos and target.cpu.arch == .aarch64) return .macos_aarch64;
        if (target.os.tag == .linux and target.cpu.arch == .x86_64) return .linux_x86_64;
        @panic("Supported hosts: macOS ARM64 and Linux x64");
    }

    /// Returns the target of `zig cc` for llc and opt.
    /// glibc 2.28 lets the Linux binaries run on older distributions.
    fn llvmZigTarget(host: Host) []const u8 {
        return switch (host) {
            .macos_aarch64 => "aarch64-macos",
            .linux_x86_64 => "x86_64-linux-gnu.2.28",
        };
    }

    /// Returns the target of the zig-sm83 compiler, or null for this machine.
    ///
    /// An explicit macOS target makes the fork read its own darwin
    /// `SDKSettings.json`, which fails to parse. musl makes the Linux
    /// compiler static.
    fn compilerZigTarget(host: Host) ?[]const u8 {
        return switch (host) {
            .macos_aarch64 => null,
            .linux_x86_64 => "x86_64-linux-musl",
        };
    }

    fn cmakeSystemName(host: Host) []const u8 {
        return switch (host) {
            .macos_aarch64 => "Darwin",
            .linux_x86_64 => "Linux",
        };
    }

    fn cmakeProcessor(host: Host) []const u8 {
        return switch (host) {
            .macos_aarch64 => "arm64",
            .linux_x86_64 => "x86_64",
        };
    }

    fn llvmTriple(host: Host) []const u8 {
        return switch (host) {
            .macos_aarch64 => "aarch64-apple-darwin",
            .linux_x86_64 => "x86_64-unknown-linux-gnu",
        };
    }
};

/// Holds the flags that every LLVM configure of this file shares.
const llvm_common_flags: []const []const u8 = &.{
    "-G",                                       "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",               "-DLLVM_TARGETS_TO_BUILD=",
    "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Z80", "-DLLVM_ENABLE_PROJECTS=",
    "-DLLVM_ENABLE_ASSERTIONS=ON",              "-DLLVM_INCLUDE_TESTS=OFF",
    "-DLLVM_INCLUDE_EXAMPLES=OFF",              "-DLLVM_INCLUDE_BENCHMARKS=OFF",
    "-DLLVM_ENABLE_ZLIB=OFF",                   "-DLLVM_ENABLE_ZSTD=OFF",
    "-DLLVM_ENABLE_LIBXML2=OFF",                "-DLLVM_ENABLE_LZMA=OFF",
    // LLVM trips CMake policy warnings, which zig build would print as errors.
    "-Wno-policy",
};

/// The tablegen tools of the build machine.
///
/// The LLVM build for a host compiles its own tablegen sources, but the
/// build machine may not run them. That build runs these instead.
const Tablegen = struct {
    /// Holds llvm-tblgen and llvm-min-tblgen.
    bin: std.Build.LazyPath,

    /// Builds the tools. A step that reads `bin` depends on it.
    step: *std.Build.Step,

    /// Configures LLVM with the system compiler and builds only the tablegen tools.
    fn build(b: *std.Build, llvm_z80: *std.Build.Dependency) Tablegen {
        const configure = b.addSystemCommand(&.{ "cmake", "-S" });
        configure.addDirectoryArg(llvm_z80.path("llvm"));
        configure.addArgs(llvm_common_flags);
        configure.addArg("-B");
        const build_dir = configure.addOutputDirectoryArg("llvm-tablegen");

        const build_run = b.addSystemCommand(&.{ "cmake", "--build" });
        build_run.addDirectoryArg(build_dir);
        build_run.addArgs(&.{ "--target", "llvm-tblgen", "llvm-min-tblgen" });
        // Ninja decides whether anything is out of date.
        build_run.has_side_effects = true;
        build_run.expectExitCode(0);

        return .{ .bin = build_dir.path(b, "bin"), .step = &build_run.step };
    }
};

/// Builds llc and opt for `host` with `zig cc`, then installs them into `llvm-sm83`.
fn installLlvm(b: *std.Build, llvm_z80: *std.Build.Dependency, tablegen: Tablegen, host: Host) void {
    const compiler_args = b.fmt("-fno-sanitize=all;-s;-target;{s};-mcpu=baseline", .{host.llvmZigTarget()});
    const zig_cc = b.fmt("{s};cc;{s}", .{ b.graph.zig_exe, compiler_args });
    const zig_cxx = b.fmt("{s};c++;{s}", .{ b.graph.zig_exe, compiler_args });

    const configure = b.addSystemCommand(&.{ "cmake", "-S" });
    configure.addDirectoryArg(llvm_z80.path("llvm"));
    configure.addArgs(llvm_common_flags);
    configure.addArgs(&.{
        "-DCMAKE_CROSSCOMPILING=True",
        b.fmt("-DCMAKE_SYSTEM_NAME={s}", .{host.cmakeSystemName()}),
        b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{host.cmakeProcessor()}),
        b.fmt("-DCMAKE_C_COMPILER={s}", .{zig_cc}),
        b.fmt("-DCMAKE_CXX_COMPILER={s}", .{zig_cxx}),
        b.fmt("-DCMAKE_ASM_COMPILER={s}", .{zig_cc}),
        "-DCMAKE_LINK_DEPENDS_USE_LINKER=OFF",
        b.fmt("-DLLVM_HOST_TRIPLE={s}", .{host.llvmTriple()}),
        b.fmt("-DLLVM_DEFAULT_TARGET_TRIPLE={s}", .{host.llvmTriple()}),
        "-DLLVM_INCLUDE_UTILS=OFF",
        "-DLLVM_BUILD_UTILS=OFF",
        "-DLLVM_INCLUDE_DOCS=OFF",
        "-DLLVM_ENABLE_LIBEDIT=OFF",
        "-DLLVM_ENABLE_LIBPFM=OFF",
        "-DLLVM_ENABLE_PLUGINS=OFF",
        "-DLLVM_ENABLE_BINDINGS=OFF",
        "-DLLVM_APPEND_VC_REV=OFF",
    });

    // CMake resolves a relative path in a cache entry from its build directory.
    // Without absolute paths, LLVM misses the native tools and stops on a target cycle.
    configure.addFileArg2(b.path("cmake/zig-ar"), .{ .prefix = "-DCMAKE_AR=", .make_absolute = true });
    configure.addFileArg2(b.path("cmake/zig-ranlib"), .{ .prefix = "-DCMAKE_RANLIB=", .make_absolute = true });
    configure.addFileArg2(tablegen.bin.path(b, "llvm-tblgen"), .{ .prefix = "-DLLVM_TABLEGEN=", .make_absolute = true });
    configure.addDirectoryArg2(tablegen.bin, .{ .prefix = "-DLLVM_NATIVE_TOOL_DIR=", .make_absolute = true });
    configure.step.dependOn(tablegen.step);

    configure.addArg("-B");
    const build_dir = configure.addOutputDirectoryArg("llvm-z80");

    const build_run = b.addSystemCommand(&.{ "cmake", "--build" });
    build_run.addDirectoryArg(build_dir);
    build_run.addArgs(&.{ "--target", "llc", "opt" });
    // Ninja decides whether anything is out of date.
    build_run.has_side_effects = true;
    build_run.expectExitCode(0);

    for ([_][]const u8{ "llc", "opt" }) |tool| {
        const tool_path = build_dir.path(b, b.fmt("bin/{s}", .{tool}));
        const install = b.addInstallFileWithDir(tool_path, .{ .custom = "llvm-sm83/bin" }, tool);

        // The path names a file of the configure step's directory, which the build step fills.
        install.step.dependOn(&build_run.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // The runtime helpers that llc's output calls.
    // A GBDK program has its own startup code, so `crt0` stays out.
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = llvm_z80.path("compiler-rt/lib/builtins/sm83"),
        .install_dir = .{ .custom = "llvm-sm83/lib" },
        .install_subdir = "sm83",
        .include_extensions = &.{ ".asm", "LICENSE" },
        .exclude_extensions = &.{ "crt0.asm", "crt0_sdcc.asm" },
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        llvm_z80.path("llvm/LICENSE.TXT"),
        .{ .custom = "llvm-sm83" },
        "LICENSE.TXT",
    ).step);
}

/// Builds the zig-sm83 compiler for `host`, then installs it with `std` into `zig-sm83`.
fn installZig(b: *std.Build, zig_sm83: *std.Build.Dependency, host: Host) void {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setCwd(zig_sm83.path(""));
    run.addPrefixedDirectoryArg("--zig-lib=", zig_sm83.path("lib"));
    run.addArgs(&.{
        "-Doptimize=ReleaseFast",
        "-Denable-llvm=false",
        "-Dno-lib",
        "-Dversion-string=0.17.0",
        // Debug info pushes the compile past the fork's max_rss limit.
        "-Dstrip",
        // Any CPU of the host's architecture runs the compiler.
        "-Dcpu=baseline",
        // The fork's compiler step declares 8 GB, more than a 7 GB CI Mac has.
        // With -Dstrip the compile stays well below it.
        "--maxrss",
        "8000000000",
    });
    if (host.compilerZigTarget()) |target| {
        run.addArg(b.fmt("-Dtarget={s}", .{target}));
    }
    run.addArg("--prefix");
    const prefix = run.addOutputDirectoryArg("zig-sm83");

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(prefix.path(b, "bin/zig"), .{ .custom = "zig-sm83/bin" }, "zig").step);

    // A ROM build reads only `std`. The rest of `lib` serves C targets.
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = zig_sm83.path("lib/std"),
        .install_dir = .{ .custom = "zig-sm83/lib" },
        .install_subdir = "std",
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(zig_sm83.path("LICENSE"), .{ .custom = "zig-sm83" }, "LICENSE").step);
}
