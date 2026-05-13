const std = @import("std");

pub fn build(b: *std.Build) void {
    const dhi_dep = b.dependency("dhi", .{});
    const core_dep = b.dependency("turboapi_core", .{});

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
    });

    const mer_mod = b.addModule("mer", .{
        .root_source_file = b.path("src/mer.zig"),
        .link_libc = true,
    });
    mer_mod.addImport("dhi_model", dhi_dep.module("model"));
    mer_mod.addImport("dhi_validator", dhi_dep.module("validator"));
    mer_mod.addImport("runtime", runtime_mod);
    mer_mod.addImport("turboapi-core", core_dep.module("turboapi-core"));
    mer_mod.addImport("mer", mer_mod);
}
