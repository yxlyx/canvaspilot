// src/lib/mock.zig — Milestone 1 demo data: a single module with a couple of
// announcements and upcoming assignments. Used when the backend isn't
// reachable or when `?mock=1` is set on the dashboard. The proposal's M1
// 1b explicitly scopes this to ONE module, so we keep it small.

const types = @import("types.zig");

pub const me: types.User = .{
    .id = "00000000-0000-0000-0000-000000000001",
    .name = "Lim Yu Xi",
    .email = "yuxi@u.nus.edu",
    .canvas_user_id = 1042,
};

pub const demo_module: types.Module = .{
    .id = "11111111-1111-1111-1111-111111111111",
    .name = "Programming Methodology II",
    .code = "CS2030S",
    .term = "AY25/26 S1",
    .last_synced_at = "2026-05-12T09:30:00Z",
};

/// All mock modules. For M1 this is just the demo module; the multi-module
/// dashboard lives in Milestone 2.
pub const modules: []const types.Module = &.{demo_module};

pub const announcements: []const types.Announcement = &.{
    .{
        .id = "ann-1",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 6 deadline extended to Friday 23:59",
        .content = "Hi all — based on feedback we've extended Lab 6 by 48 hours.",
        .posted_at = "2026-05-12T08:15:00Z",
        .summary = "Lab 6 due Fri 23:59. New testcases on Coursemology.",
    },
    .{
        .id = "ann-2",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lecture 9 slides + recording posted",
        .content = "Slides for lecture 9 (immutable lists, lazy streams) are up.",
        .posted_at = "2026-05-10T16:42:00Z",
        .summary = "Lecture 9: immutable lists, lazy streams.",
    },
};

pub const tasks: []const types.Task = &.{
    .{
        .id = "task-1",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 6: Functional collections",
        .task_type = "assignment",
        .due_at = "2026-05-15T15:59:00Z",
        .completed = false,
        .source_url = "https://canvas.nus.edu.sg/courses/1/assignments/61",
    },
    .{
        .id = "task-2",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 7: Streams",
        .task_type = "assignment",
        .due_at = "2026-05-22T15:59:00Z",
        .completed = false,
        .source_url = "https://canvas.nus.edu.sg/courses/1/assignments/62",
    },
};
