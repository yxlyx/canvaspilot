// app/index.zig — landing page. Authenticated users get sent straight to the
// dashboard so the root URL feels like a real app, not a marketing page.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Home",
    .description = "A student workspace for source-backed study notes, Q&A, and flashcards.",
};

pub fn render(req: mer.Request) mer.Response {
    if (lib.session.fromRequest(req).isAuthenticated()) {
        return mer.redirect("/dashboard", .see_other);
    }

    const body =
        \\<section class="cp-hero">
        \\  <div class="cp-hero-copy">
        \\    <div class="cp-hero-badge">Student course workspace</div>
        \\    <h1 class="cp-hero-title">Turn course material into a <em>study OS.</em></h1>
        \\    <p class="cp-hero-sub">
        \\      Collect sources, compile wiki notes, ask cited questions, and practise
        \\      flashcards from one workspace built for revision.
        \\    </p>
        \\    <div class="cp-hero-actions">
        \\      <a class="cp-btn cp-btn-primary" href="/login">Sign in</a>
        \\      <a class="cp-btn cp-btn-ghost" href="/dashboard?mock=1">View demo data</a>
        \\    </div>
        \\  </div>
        \\  <div class="cp-hero-panel" aria-label="CanvasPilot workflow preview">
        \\    <div class="cp-course-card">
        \\      <div class="cp-course-top">
        \\        <div>
        \\          <div class="cp-course-code">CS2030S</div>
        \\          <div class="cp-course-name">Programming Methodology</div>
        \\        </div>
        \\        <span class="cp-course-pill">Ready</span>
        \\      </div>
        \\      <div class="cp-course-progress"><span></span></div>
        \\      <div class="cp-flow-list">
        \\        <div class="cp-flow-row">
        \\          <span class="cp-flow-dot"></span>
        \\          <span class="cp-flow-label">Indexed source library</span>
        \\          <span class="cp-flow-meta">18 chunks</span>
        \\        </div>
        \\        <div class="cp-flow-row">
        \\          <span class="cp-flow-dot"></span>
        \\          <span class="cp-flow-label">Generated wiki pages</span>
        \\          <span class="cp-flow-meta">4 pages</span>
        \\        </div>
        \\        <div class="cp-flow-row">
        \\          <span class="cp-flow-dot"></span>
        \\          <span class="cp-flow-label">Cited Q&amp;A ready</span>
        \\          <span class="cp-flow-meta">grounded</span>
        \\        </div>
        \\        <div class="cp-flow-row">
        \\          <span class="cp-flow-dot"></span>
        \\          <span class="cp-flow-label">Flashcard practice queue</span>
        \\          <span class="cp-flow-meta">12 cards</span>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </div>
        \\</section>
        \\<section class="cp-feature-strip" aria-label="Product flow">
        \\  <article class="cp-feature-card">
        \\    <div class="cp-feature-icon">1</div>
        \\    <div class="cp-feature-title">Source library</div>
        \\    <p class="cp-feature-copy">Keep notes, briefs, links, and readings in one place.</p>
        \\  </article>
        \\  <article class="cp-feature-card">
        \\    <div class="cp-feature-icon">2</div>
        \\    <div class="cp-feature-title">Cited wiki</div>
        \\    <p class="cp-feature-copy">Compile Markdown pages that stay traceable to source material.</p>
        \\  </article>
        \\  <article class="cp-feature-card">
        \\    <div class="cp-feature-icon">3</div>
        \\    <div class="cp-feature-title">Grounded Q&amp;A</div>
        \\    <p class="cp-feature-copy">Ask questions and keep citations visible beside every answer.</p>
        \\  </article>
        \\  <article class="cp-feature-card">
        \\    <div class="cp-feature-icon">4</div>
        \\    <div class="cp-feature-title">Practice loop</div>
        \\    <p class="cp-feature-copy">Review flashcards and build evidence for weak-topic checks.</p>
        \\  </article>
        \\</section>
    ;
    return mer.html(body);
}
