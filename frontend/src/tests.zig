// Test root for first-party modules that are build-module imports in the app.

comptime {
    _ = @import("lib/form.zig");
    _ = @import("lib/time.zig");
}
