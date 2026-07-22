const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Home",
    .description = "Turn course sources into a cited wiki, grounded answers, and useful review.",
};

pub fn render(req: mer.Request) mer.Response {
    if (lib.session.fromRequest(req).isAuthenticated()) {
        return mer.redirect("/dashboard", .see_other);
    }

    const body =
        \\<main class="wb-landing" id="main">
        \\  <section class="wb-hero">
        \\    <header class="wb-marketing-nav">
        \\      <a class="wb-brand" href="/"><span>W</span><strong>WikiBase</strong></a>
        \\      <nav aria-label="Marketing navigation"><a href="#workflow">Workflow</a><a href="#evidence">Evidence</a><a href="#study">Study</a></nav>
        \\      <div class="wb-marketing-actions">
        \\        <button class="wb-theme-toggle" type="button" data-cp-theme-toggle aria-label="Switch to dark mode" title="Switch colour theme"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z"/></svg></button>
        \\        <a href="/login">Sign in</a><a class="wb-button wb-button-dark wb-button-small" href="/login?mode=signup">Build your wiki</a>
        \\      </div>
        \\    </header>
        \\    <div class="wb-hero-copy">
        \\      <p class="wb-eyebrow">A quieter way to master a module</p>
        \\      <h1>Your course knowledge, built to last.</h1>
        \\      <p>WikiBase turns the material you already have into a connected, cited study space you can trust.</p>
        \\      <div><a class="wb-button wb-button-dark" href="/login?mode=signup">Start with your sources <span aria-hidden="true">↗</span></a><a class="wb-button wb-button-ghost" href="/dashboard?mock=1">View the prototype</a></div>
        \\    </div>
        \\    <div class="wb-hero-stage">
        \\      <div class="wb-product-screen wb-product-screen-hero">
        \\        <div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Student workspace</b><em>WikiBase</em></div>
        \\        <div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-dashboard-light.png" alt="WikiBase student workspace dashboard" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-dashboard-dark.png" alt="" width="1440" height="900"></div>
        \\      </div>
        \\    </div>
        \\    <p class="wb-hero-note"><span>Your whole module in view</span><span>Every answer tied to evidence</span></p>
        \\  </section>
        \\  <section class="wb-promises" aria-label="How WikiBase helps">
        \\    <article><span>01</span><div><h2>Bring the evidence</h2><p>Keep slides, readings, links, and notes in one source library.</p></div></article>
        \\    <article><span>02</span><div><h2>Build understanding</h2><p>Move through a connected wiki with every claim tied back to its source.</p></div></article>
        \\    <article><span>03</span><div><h2>Strengthen recall</h2><p>Ask grounded questions and review flashcards without losing context.</p></div></article>
        \\  </section>
        \\  <section class="wb-landscape">
        \\    <img src="/media/landscape-beginning-dithered.png" alt="Broken classical academy in a lush landscape at dawn" width="1600" height="1000">
        \\    <div><p class="wb-eyebrow">A place to begin</p><h2>Scattered material can still become a structure.</h2></div>
        \\  </section>
        \\  <section id="workflow" class="wb-editorial wb-feature-pair">
        \\    <div class="wb-editorial-copy"><p class="wb-eyebrow">Begin with what is true</p><h2>A source library that keeps its bearings.</h2><p>See what has been indexed, what is still processing, and which pieces of your wiki each source supports.</p><a class="wb-arrow-link" href="/sources">Explore the source library <span aria-hidden="true">→</span></a></div>
        \\    <div class="wb-product-screen wb-product-screen-right"><div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Source library</b><em>WikiBase</em></div><div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-sources-light.png" alt="WikiBase source library with document previews" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-sources-dark.png" alt="" width="1440" height="900"></div></div>
        \\  </section>
        \\  <section class="wb-landscape"><img src="/media/landscape-progress-dithered.png" alt="Partially restored classical academy in the same landscape" width="1600" height="1000"><div><p class="wb-eyebrow">Understanding compounds</p><h2>Every connection repairs the whole.</h2></div></section>
        \\  <section id="evidence" class="wb-editorial wb-evidence">
        \\    <div class="wb-section-heading"><p class="wb-eyebrow">Trace every idea</p><h2>Read, ask, and verify without breaking your flow.</h2></div>
        \\    <div class="wb-screenshot-grid">
        \\      <article><div><span class="wb-step-chip">Wiki</span><h3>Knowledge that stays connected.</h3></div><div class="wb-product-screen"><div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Generated wiki</b><em>WikiBase</em></div><div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-wiki-light.png" alt="WikiBase generated wiki" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-wiki-dark.png" alt="" width="1440" height="900"></div></div></article>
        \\      <article><div><span class="wb-step-chip">Ask</span><h3>Answers that show their work.</h3></div><div class="wb-product-screen wb-product-screen-right"><div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Cited Q&amp;A</b><em>WikiBase</em></div><div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-chat-light.png" alt="WikiBase cited question and answer workspace" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-chat-dark.png" alt="" width="1440" height="900"></div></div></article>
        \\    </div>
        \\  </section>
        \\  <section class="wb-landscape"><img src="/media/landscape-completion-dithered.png" alt="Fully restored classical academy in the same grand landscape" width="1600" height="1000"><div><p class="wb-eyebrow">A stronger structure</p><h2>What you tend becomes what you know.</h2></div></section>
        \\  <section id="study" class="wb-editorial wb-study">
        \\    <div class="wb-section-heading"><p class="wb-eyebrow">Study with evidence</p><h2>Turn understanding into something you can recall.</h2></div>
        \\    <div class="wb-study-grid">
        \\      <div class="wb-product-screen"><div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Flashcard review</b><em>WikiBase</em></div><div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-flashcards-light.png" alt="WikiBase flashcard review" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-flashcards-dark.png" alt="" width="1440" height="900"></div></div>
        \\      <div class="wb-product-screen wb-product-screen-right wb-product-screen-lifted"><div class="wb-screen-bar"><span aria-hidden="true"><i></i><i></i><i></i></span><b>Learning progress</b><em>WikiBase</em></div><div class="wb-screen-viewport"><img class="wb-theme-shot wb-theme-shot-light" src="/media/product-dashboard-light.png" alt="WikiBase learning progress dashboard" width="1440" height="900"><img class="wb-theme-shot wb-theme-shot-dark" src="/media/product-dashboard-dark.png" alt="" width="1440" height="900"></div></div>
        \\    </div>
        \\  </section>
        \\  <section class="wb-closing"><a class="wb-brand" href="/"><span>W</span><strong>WikiBase</strong></a><h2>Build a knowledge base worthy of the work.</h2><p>Start with one module. Keep every source close. Let the structure grow.</p><a class="wb-button wb-button-light" href="/login?mode=signup">Enter WikiBase <span aria-hidden="true">↗</span></a></section>
        \\  <footer class="wb-footer"><p>WikiBase · Source-grounded study</p><div><a href="/sources">Sources</a><a href="/wiki">Wiki</a><a href="/chat">Ask</a><a href="/flashcards">Flashcards</a></div></footer>
        \\</main>
    ;
    return mer.html(body);
}
