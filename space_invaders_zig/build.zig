//! build.zig - Space Invaders Zig 版のビルド。
//!   zig build          実行ファイルを作る
//!   zig build test     テストを回す（logic 単体＋replay 通し）
//! この VM のように SDL の開発ファイルが標準の場所に無い環境では、
//! -Dsdl-root=<SDL の展開ツリー> で include / lib の場所を足せる
//! （ツリーの下に usr/include と usr/lib/<arch> がある形を想定）。

const std = @import("std");

fn linkSdl(b: *std.Build, compile: *std.Build.Step.Compile, sdl_root: ?[]const u8) void {
    if (sdl_root) |root| {
        compile.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });
        compile.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include/SDL2" }) });
        compile.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include/x86_64-linux-gnu" }) });
        compile.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib/x86_64-linux-gnu" }) });
    }
    compile.root_module.linkSystemLibrary("SDL2", .{});
    compile.root_module.linkSystemLibrary("SDL2_image", .{});
    compile.root_module.linkSystemLibrary("SDL2_mixer", .{});
    compile.root_module.linkSystemLibrary("SDL2_ttf", .{});
    compile.root_module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl_root = b.option([]const u8, "sdl-root", "SDL dev tree root (expects usr/include and usr/lib/<arch> under it)");

    const sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const logic_mod = b.addModule("logic", .{
        .root_source_file = b.path("src/logic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("src/assets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sdl", .module = sdl_mod }},
    });
    const game_mod = b.addModule("game", .{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl", .module = sdl_mod },
            .{ .name = "logic", .module = logic_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl", .module = sdl_mod },
            .{ .name = "game", .module = game_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });
    const exe = b.addExecutable(.{ .name = "space_invaders", .root_module = exe_mod });
    linkSdl(b, exe, sdl_root);
    b.installArtifact(exe);

    const test_step = b.step("test", "Run tests");

    const logic_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_logic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "logic", .module = logic_mod }},
    });
    const logic_tests = b.addTest(.{ .root_module = logic_test_mod });
    test_step.dependOn(&b.addRunArtifact(logic_tests).step);

    const replay_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_replay.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl", .module = sdl_mod },
            .{ .name = "logic", .module = logic_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "game", .module = game_mod },
        },
    });
    const replay_tests = b.addTest(.{ .root_module = replay_test_mod });
    linkSdl(b, replay_tests, sdl_root);
    test_step.dependOn(&b.addRunArtifact(replay_tests).step);
}
