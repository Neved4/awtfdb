const std = @import("std");
const deps = @import("./deps.zig");

const EXECUTABLES = .{
    .{ "awtfdb-manage", "src/main.zig" },
    .{ "awtfdb-watcher", "src/rename_watcher_main.zig" },
    .{ "awtfdb-janitor", "src/janitor_main.zig" },
    .{ "ainclude", "src/include_main.zig" },
    .{ "afind", "src/find_main.zig" },
    .{ "als", "src/ls_main.zig" },
    .{ "arm", "src/rm_main.zig" },
    .{ "atags", "src/tags_main.zig" },
    .{ "awtfdb-metrics", "src/metrics_main.zig" },
};

fn addGraphicsMagick(thing: anytype) void {
    thing.linkLibC();
    thing.addIncludePath("/usr/include");
    thing.addIncludePath("/usr/include/GraphicsMagick");
}

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const exe_tests = b.addTest(
        .{
            .root_source_file = .{ .path = "src/main.zig" },
            .optimize = optimize,
            .target = target,
        },
    );

    addGraphicsMagick(exe_tests);
    deps.addAllTo(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);

    if (optimize == .Debug) {
        const single_exe = b.addExecutable(
            .{
                .name = "wrapper-awtfdb",
                .root_source_file = .{ .path = "src/wrapmain.zig" },
                .optimize = optimize,
                .target = target,
            },
        );

        deps.addAllTo(single_exe);
        addGraphicsMagick(single_exe);

        const hardlink_install = try b.allocator.create(CustomHardLinkStep);
        hardlink_install.* = .{
            .builder = b,
            .step = std.build.Step.init(
                .custom,
                "link the utils",
                b.allocator,
                CustomHardLinkStep.make,
            ),
            .exe = single_exe,
        };
        hardlink_install.step.dependOn(&single_exe.step);

        b.getInstallStep().dependOn(&hardlink_install.step);
    } else {
        // release modes build all exes separately
        inline for (EXECUTABLES) |exec_decl| {
            const exec_name = exec_decl.@"0";
            const exec_entrypoint = exec_decl.@"1";

            var tool_exe = b.addExecutable(
                .{
                    .name = exec_name,
                    .root_source_file = .{ .path = exec_entrypoint },
                    .optimize = optimize,
                    .target = target,
                },
            );

            tool_exe.install();
            addGraphicsMagick(tool_exe);
            deps.addAllTo(tool_exe);
        }
    }
}

const CustomHardLinkStep = struct {
    builder: *std.build.Builder,
    step: std.build.Step,
    exe: *std.build.LibExeObjStep,

    const Self = @This();

    fn make(step: *std.build.Step) !void {
        const self: *Self = @fieldParentPtr(Self, "step", step);
        const builder = self.builder;

        inline for (EXECUTABLES) |exec_decl| {
            const exec_name = exec_decl.@"0";
            const full_dest_path = builder.getInstallPath(.{ .bin = {} }, exec_name);
            try builder.updateFile(self.exe.output_path_source.path.?, full_dest_path);
        }
    }
};
