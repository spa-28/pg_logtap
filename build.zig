const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // pgzx from the published fork: provides the "pgzx" module (C bindings
    // module pgzx.c + wrappers). Requires pg_config on PATH at configure time
    // (PG_CONFIG env overrides the binary); it selects the target PG major.
    const pgzx_mod = b.dependency("pgzx", .{}).module("pgzx");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pgzx", .module = pgzx_mod },
        },
    });
    // filter.zig's regex box: compiled against the TARGET libc's <regex.h>
    // (zig cc), so regex_t size/layout is the real one for glibc, musl, any
    // arch — a hardcoded size in Zig was stack corruption on the first
    // libc it didn't match.
    mod.addCSourceFiles(.{ .files = &.{"src/c/regex_shim.c"} });

    const lib = b.addLibrary(.{
        .name = "pg_logtap",
        .root_module = mod,
        .linkage = .dynamic,
    });
    // PostgreSQL symbols (palloc, elog, ...) resolve when the postmaster loads us.
    lib.linker_allow_shlib_undefined = true;
    // PG dlopens "$libdir/pg_logtap" verbatim: no lib prefix, .so appended.
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{ .dest_sub_path = "pg_logtap.so" }).step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // filter.zig calls libc regcomp/regexec
    });
    test_mod.addCSourceFiles(.{ .files = &.{"src/c/regex_shim.c"} });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Check formatting");
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true });
    fmt_step.dependOn(&fmt.step);

    const zlinter = @import("zlinter");
    const lint_step = b.step("lint", "Lint first-party sources");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addPaths(.{
            .include = &.{b.path("src")},
        });
        break :step builder.build();
    });
}
