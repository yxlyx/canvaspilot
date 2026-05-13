// src/lib/time.zig — human-friendly date/time helpers.
// Inputs are ISO-8601 strings from the backend (UTC, ends in Z or +00:00).

const std = @import("std");

const SECS_PER_MIN: i64 = 60;
const SECS_PER_HOUR: i64 = 60 * 60;
const SECS_PER_DAY: i64 = 24 * 60 * 60;

const MONTHS_SHORT = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Parses the date portion of an ISO-8601 timestamp ("YYYY-MM-DDTHH:MM:SS...").
/// Returns the seconds since the Unix epoch, or null if the input is malformed.
pub fn parseIsoSecs(iso: []const u8) ?i64 {
    if (iso.len < 19) return null;
    if (iso[4] != '-' or iso[7] != '-') return null;
    if (iso[10] != 'T' and iso[10] != ' ') return null;
    if (iso[13] != ':' or iso[16] != ':') return null;

    const year = std.fmt.parseInt(i64, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, iso[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, iso[17..19], 10) catch return null;

    return daysFromCivil(year, month, day) * SECS_PER_DAY +
        hour * SECS_PER_HOUR + minute * SECS_PER_MIN + second;
}

/// Days since 1970-01-01 for a Gregorian date. Algorithm from Howard Hinnant.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Format an absolute moment in time as "12 May, 18:42 UTC".
pub fn formatAbsolute(allocator: std.mem.Allocator, iso: []const u8) ![]const u8 {
    const secs = parseIsoSecs(iso) orelse return allocator.dupe(u8, "—");
    const day_secs = @mod(secs, SECS_PER_DAY);
    const hour: i64 = @divTrunc(day_secs, SECS_PER_HOUR);
    const minute: i64 = @divTrunc(@mod(day_secs, SECS_PER_HOUR), SECS_PER_MIN);
    const civ = civilFromDays(@divFloor(secs, SECS_PER_DAY));
    const mi: usize = @intCast(civ.m - 1);
    return std.fmt.allocPrint(allocator, "{d} {s}, {d:0>2}:{d:0>2} UTC", .{
        civ.d,
        MONTHS_SHORT[mi],
        hour,
        minute,
    });
}

/// Format a duration relative to `now_secs`. Examples: "in 3h", "in 2d", "5m ago".
pub fn formatRelative(allocator: std.mem.Allocator, iso: []const u8, now_secs: i64) ![]const u8 {
    const target = parseIsoSecs(iso) orelse return allocator.dupe(u8, "—");
    const delta = target - now_secs;
    const abs_delta: i64 = if (delta < 0) -delta else delta;

    var amount: i64 = 0;
    var unit: []const u8 = "";
    if (abs_delta < 60) {
        amount = abs_delta;
        unit = "s";
    } else if (abs_delta < SECS_PER_HOUR) {
        amount = @divTrunc(abs_delta, SECS_PER_MIN);
        unit = "m";
    } else if (abs_delta < SECS_PER_DAY) {
        amount = @divTrunc(abs_delta, SECS_PER_HOUR);
        unit = "h";
    } else if (abs_delta < SECS_PER_DAY * 30) {
        amount = @divTrunc(abs_delta, SECS_PER_DAY);
        unit = "d";
    } else {
        amount = @divTrunc(abs_delta, SECS_PER_DAY * 30);
        unit = "mo";
    }

    return if (delta >= 0)
        std.fmt.allocPrint(allocator, "in {d}{s}", .{ amount, unit })
    else
        std.fmt.allocPrint(allocator, "{d}{s} ago", .{ amount, unit });
}

/// "soonish" returns true when due_at falls within the next 48 hours.
pub fn isUrgent(iso: []const u8, now_secs: i64) bool {
    const target = parseIsoSecs(iso) orelse return false;
    const delta = target - now_secs;
    return delta >= 0 and delta <= SECS_PER_DAY * 2;
}

/// Wall-clock seconds since the Unix epoch. `std.time.timestamp()` was
/// removed in Zig 0.16, so we read REALTIME directly via libc — same
/// trick merjs's server.zig uses internally.
pub fn nowSecs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ── Tests ──────────────────────────────────────────────────────────────────
const testing = std.testing;

test "parseIsoSecs handles a well-formed UTC timestamp" {
    const got = parseIsoSecs("2026-05-12T09:30:00Z");
    try testing.expect(got != null);
    try testing.expectEqual(@as(i64, 1778578200), got.?);
}

test "parseIsoSecs rejects malformed input" {
    try testing.expectEqual(@as(?i64, null), parseIsoSecs("not-a-date"));
    try testing.expectEqual(@as(?i64, null), parseIsoSecs("2026/05/12 09:30"));
}

test "isUrgent flags deadlines within 48h" {
    const now: i64 = 1778578200; // 2026-05-12T09:30:00Z
    // 1 day later
    try testing.expect(isUrgent("2026-05-13T09:30:00Z", now));
    // 5 days later
    try testing.expect(!isUrgent("2026-05-17T09:30:00Z", now));
    // already passed
    try testing.expect(!isUrgent("2026-05-10T09:30:00Z", now));
}
