// main.zig -- app entry point.
// Usage:
//   zig build serve               (dev server on :3001, hot reload)
//   zig build serve -- --port 8080
//   zig build serve -- --no-dev   (disable hot reload)

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try runtime.init(alloc);
    defer runtime.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    // Load .env before threads start.
    mer.loadDotenv(alloc);

    var config = mer.Config{
        .host = "127.0.0.1",
        .port = 3001,
        .dev = true,
    };

    var do_prerender = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            config.host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
            config.dev = false;
        } else if (std.mem.eql(u8, args[i], "--debug")) {
            config.debug = true;
        } else if (std.mem.eql(u8, args[i], "--kuri-port") and i + 1 < args.len) {
            config.kuri_port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, args[i], "--prerender")) {
            do_prerender = true;
        }
    }

    // Build router from generated routes.
    var router = mer.Router.fromGenerated(alloc, @import("routes"));
    defer router.deinit();

    // SSG mode: pre-render pages to dist/ and exit.
    if (do_prerender) {
        try mer.runPrerender(alloc, &router);
        return;
    }

    // File watcher (dev mode only).
    var watcher = mer.Watcher.init(alloc, "app");
    defer watcher.deinit();

    if (config.dev) {
        const wt = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher});
        wt.detach();
        log.info("hot reload active -- watching app/", .{});
    }

    var server = mer.Server.init(alloc, config, &router, if (config.dev) &watcher else null);
    try server.listen();
}

// ---------------------------------------------------------------------------
// Renderer unit tests. The test runner only collects tests from this root
// module, so wiki markdown coverage lives here and calls into lib.markdown.
// ---------------------------------------------------------------------------

const testing = std.testing;
const markdown = @import("lib").markdown;

test "markdown slugify mirrors backend normalization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("week-1-limits-continuity", markdown.slugify(alloc, " Week 1: Limits & Continuity "));
    try testing.expectEqualStrings("page", markdown.slugify(alloc, "!!!"));
    try testing.expectEqualStrings("limits-notes", markdown.slugify(alloc, "Limits Notes"));
}

test "markdown renderInline escapes literal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderInline(alloc, &out.writer, "a < b & c > d");
    try testing.expectEqualStrings("a &lt; b &amp; c &gt; d", out.written());
}

test "markdown renderInline links wikilinks to slug paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderInline(alloc, &out.writer, "see [[Limits Notes]] for more");
    try testing.expectEqualStrings(
        "see <a href=\"/wiki/limits-notes\">Limits Notes</a> for more",
        out.written(),
    );
}

test "markdown renderInline renders inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderInline(alloc, &out.writer, "Topics: `calculus`, `limits`");
    try testing.expectEqualStrings(
        "Topics: <code>calculus</code>, <code>limits</code>",
        out.written(),
    );
}

test "markdown renderInline renders footnote citation refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderInline(alloc, &out.writer, "Limits describe behavior. [^c1]");
    try testing.expectEqualStrings(
        "Limits describe behavior. <sup class=\"cp-cite\">c1</sup>",
        out.written(),
    );
}

test "markdown renderInline escapes code and title contents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderInline(alloc, &out.writer, "use `a < b` and [[A & B]]");
    try testing.expectEqualStrings(
        "use <code>a &lt; b</code> and <a href=\"/wiki/a-b\">A &amp; B</a>",
        out.written(),
    );
}

test "markdown renderMarkdown handles blockquote list and references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\# Limits Notes
        \\
        \\> Limits describe behavior near a point.
        \\
        \\## Definition
        \\
        \\Limits describe nearby function behavior. [^c1]
        \\
        \\## References
        \\
        \\[^c1]: Limits Notes Citation: Section 1
    ;
    var out: std.Io.Writer.Allocating = .init(alloc);
    try markdown.renderMarkdown(alloc, &out.writer, src);
    const html = out.written();
    try testing.expect(std.mem.indexOf(u8, html, "<h1>Limits Notes</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<blockquote>Limits describe behavior near a point.</blockquote>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<h2>Definition</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<sup class=\"cp-cite\">c1</sup>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<ul class=\"cp-refs\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Limits Notes Citation: Section 1") != null);
}
