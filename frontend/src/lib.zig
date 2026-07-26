// src/lib.zig — single shared module re-exported as `@import("lib")` for all
// pages and api routes. Everything frontend pages need to talk to FastAPI,
// read sessions, format times, or fall back to mock data sits behind here.

pub const config = @import("lib/config.zig");
pub const form = @import("lib/form.zig");
pub const types = @import("lib/types.zig");
pub const time = @import("lib/time.zig");
pub const mock = @import("lib/mock.zig");
pub const session = @import("lib/session.zig");
pub const backend = @import("lib/backend.zig");
pub const ui = @import("lib/ui.zig");
pub const chat = @import("lib/chat.zig");
pub const markdown = @import("lib/markdown.zig");
pub const m3 = @import("lib/m3.zig");
pub const mutation = @import("lib/mutation.zig");
pub const navigation = @import("lib/navigation.zig");
pub const settings_ui = @import("lib/settings_ui.zig");
pub const processing_ui = @import("lib/processing_ui.zig");
