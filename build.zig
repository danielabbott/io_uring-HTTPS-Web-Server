const std = @import("std");
const build_ = @import("std").build;
const LibExeObjStep = build_.LibExeObjStep;
const Builder = std.build.Builder;
const builtin = @import("builtin");

fn addSettings(exe: *LibExeObjStep) void {
    exe.setTarget(.{
        .cpu_arch = std.Target.Cpu.Arch.x86_64,
        // .os_tag = .linux,
        // .os_version_min = .{
        //     .semver = .{
        //         .major = 5,
        //         .minor = 6,
        //         .patch = 0,
        //     },
        // },
    });

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkSystemLibrary("uring");
    exe.addIncludeDir("/usr/include");
    exe.addIncludeDir("/usr/include/x86_64-linux-gnu");
    exe.addCSourceFile("src/uring.c", &[0]([]const u8){});
}

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("webserver", "src/Main.zig");
    exe.setBuildMode(mode);
    addSettings(exe);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");
    const t = b.addTest("src/Main.zig");
    addSettings(t);
    test_step.dependOn(&t.step);
}
