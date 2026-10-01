import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The dry-run report: one HTML page of proposed groups and picks.
enum Report {
    static var page: URL { page(in: Paths.report) }
    static func page(in folder: URL) -> URL { folder.appendingPathComponent("index.html") }

    /// Relative paths of one photo's images inside the report folder.
    struct Images: Codable {
        var thumb: String
        /// Large copy for the click-to-enlarge viewer.
        var full: String
    }

    static func write(_ run: Run, items: [String: Item], offline: Bool, progress: (Int, Int) -> Void) async throws {
        let folder = try resetFolder(Paths.report)

        // Grid thumbnails come from the Mac's local previews; the large copies
        // may need iCloud, like the re-scoring step.
        let ids = run.groups.flatMap { $0.photos.map(\.id) }
        let fetch: Library.Fetch = offline ? .localOnly : .download(timeout: 60)
        var images: [String: Images] = [:]
        var done = 0
        await withTaskGroup(of: (String, Images?).self) { tasks in
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let (index, id) = (next, ids[next])
                next += 1
                tasks.addTask {
                    guard let item = items[id],
                          let thumb = await item.image(maxSide: thumbSide, fetch: .localOnly),
                          let full = await item.image(maxSide: fullSide, fetch: fetch)
                    else { return (id, nil) }
                    return (id, save(thumb: thumb, full: full, as: "\(index)", in: folder))
                }
            }
            for _ in 0..<6 { add() }
            for await (id, files) in tasks {
                images[id] = files
                done += 1
                progress(done, ids.count)
                add()
            }
        }

        try render(run, images: images, in: folder)
    }

    static let thumbSide: CGFloat = 720
    static let fullSide: CGFloat = 2048

    /// Empties a report folder and returns it.
    static func resetFolder(_ folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.appendingPathComponent("img", isDirectory: true), withIntermediateDirectories: true)
        return folder
    }

    static func save(thumb: CGImage, full: CGImage, as name: String, in folder: URL) -> Images? {
        let images = Images(thumb: "img/\(name)-s.jpg", full: "img/\(name)-l.jpg")
        guard writeJPEG(thumb, to: folder.appendingPathComponent(images.thumb), quality: 0.8),
              writeJPEG(full, to: folder.appendingPathComponent(images.full), quality: 0.85)
        else { return nil }
        return images
    }

    static func render(_ run: Run, images: [String: Images], in folder: URL) throws {
        try html(run, images: images).write(to: page(in: folder), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(images).write(to: folder.appendingPathComponent("images.json"), options: .atomic)
    }

    /// The report's image files by photo id, for `pixelgraph review`.
    static func manifest(in folder: URL) throws -> [String: Images] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("images.json")) else {
            throw ValidationError("No review images yet. Run `pixelgraph scan` again to make them.")
        }
        return try JSONDecoder().decode([String: Images].self, from: data)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - HTML

    private static func html(_ run: Run, images: [String: Images]) -> String {
        let photos = run.groups.reduce(0) { $0 + $1.photos.count }
        let toMove = run.toMove.count
        let moved = run.groups.reduce(0) { $0 + $1.pick.moved.count }
        let byModel = run.groups.filter { $0.pick.decidedBy == "apple-model" }.count
        let flagged = run.groups.filter { g in g.pick.suggestions.keys.contains { g.pick.willMove($0) } }.count

        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("MMMd jmm")
        let time = DateFormatter()
        time.timeStyle = .medium
        time.dateStyle = .none

        var filters = #"<button class="on" data-f="all">All <b>\#(run.groups.count)</b></button>"#
        filters += #"<button data-f="moving">To move <b>\#(run.groups.filter { g in g.photos.contains { g.pick.willMove($0.id) } }.count)</b></button>"#
        if flagged > 0 { filters += #"<button data-f="flagged">Flagged <b>\#(flagged)</b></button>"# }
        if byModel > 0 { filters += #"<button data-f="model">Close calls <b>\#(byModel)</b></button>"# }

        var cards = ""
        for (n, group) in run.groups.enumerated() {
            let pick = group.pick
            let moving = group.photos.filter { pick.willMove($0.id) }.count
            let kept = group.photos.filter { pick.isKept($0.id) }.count
            var tiles = ""
            for photo in Run.displayOrder(group) {
                let id = photo.id
                let state = pick.keepers.contains(id) ? "best" : pick.isKept(id) ? "keep" : pick.moved.contains(id) ? "moved" : "move"
                let files = images[id]
                let img = files.map { #"<img loading="lazy" src="\#($0.thumb)" alt="">"# } ?? #"<div class="missing">No preview</div>"#
                let mark: String
                let caption: String
                switch state {
                case "best":
                    mark = #"<span class="mark best">★ Best</span>"#
                    caption = #"<p class="note best">\#(escape(pick.notes[id] ?? ""))</p>"#
                case "keep":
                    mark = #"<span class="mark keep">Keep</span>"#
                    caption = #"<p class="note">Keep · \#(escape(pick.decidedBy == "you" ? "you chose" : pick.notes[id] ?? ""))</p>"#
                case "moved":
                    mark = #"<span class="mark moved">Moved</span>"#
                    caption = #"<p class="note muted">Moved to Duplicates</p>"#
                default:
                    mark = #"<span class="check" aria-label="Selected to move">✓</span>"#
                    let why = pick.reasons[id] ?? pick.suggestions[id]
                    caption = why.map { #"<p class="note move">Move · <span class="why">\#(escape($0))</span></p>"# }
                        ?? #"<p class="note move">Move · \#(escape(pick.notes[id] ?? ""))</p>"#
                }
                let faces = photo.faceCount > 0 ? " · faces \(Int(photo.faceQuality * 100))" : ""
                tiles += """
                    <figure class="\(state)"\(files.map { #" data-full="\#($0.full)""# } ?? "")>
                      <button class="img" aria-label="Enlarge">\(img)\(mark)</button>
                      <figcaption>\(caption)
                        <p class="meta">\(time.string(from: photo.date)) · \(photo.width)×\(photo.height) · look \(Int((photo.aesthetic + 1) * 50))\(faces)</p>
                      </figcaption>
                    </figure>
                    """
            }
            let isFlagged = pick.suggestions.keys.contains { pick.willMove($0) }
            var badges = ""
            if group.reviewed == true { badges += #"<span class="badge done">✓ Reviewed</span>"# }
            if pick.decidedBy == "apple-model" { badges += #"<span class="badge model">✦ Close call</span>"# }
            cards += """
                <section class="group" data-moving="\(moving > 0)" data-flagged="\(isFlagged)" data-model="\(pick.decidedBy == "apple-model")" data-title="\(escape(day.string(from: group.photos[0].date)))">
                  <header>
                    <h2>\(escape(day.string(from: group.photos[0].date)))</h2>
                    <span class="kind">\(group.kind.title)</span>\(badges)
                    <span class="counts">keep \(kept) · <b>move \(moving)</b>\(pick.moved.isEmpty ? "" : " · \(pick.moved.count) moved") · group \(n + 1)</span>
                  </header>
                  <div class="grid">\(tiles)</div>
                </section>
                """
        }
        if run.groups.isEmpty {
            cards = #"<p class="empty">No near-identical photos found.</p>"#
        }

        let destination = run.source?.isPhotos == false ? "the “\(Files.duplicatesFolder)” folder" : "the “\(Library.duplicatesAlbum)” album"
        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>PixelGraph Review</title>
            <style>\(css)</style></head>
            <body>
            <main>
              <p class="brand">PixelGraph</p>
              <h1>\(escape(run.scope))</h1>
              <p class="scope">\(run.groups.count) groups · \(photos) photos · scanned \(day.string(from: run.date))</p>
              <div class="stats">
                <div><b>\(run.scanned.formatted())</b><span>photos scanned</span></div>
                <div><b>\(run.groups.count.formatted())</b><span>groups of lookalikes</span></div>
                <div class="accent"><b>\(toMove.formatted())</b><span>selected to move</span></div>
                <div><b>\(moved.formatted())</b><span>moved to Duplicates</span></div>
              </div>
              <nav>
                <div class="filters">\(filters)</div>
                <div class="sizes" role="group" aria-label="Photo size">
                  <button data-size="s" aria-label="Small photos">S</button><button data-size="m" aria-label="Medium photos">M</button><button data-size="l" aria-label="Large photos">L</button>
                </div>
              </nav>
              \(cards)
            </main>
            <footer class="bar">
              <span>\(toMove > 0 ? "<b>\(toMove) selected</b> to move to \(destination)." : "Nothing selected to move.")</span>
              <span class="hint">Change selections and move them in the terminal: <code>pixelgraph review</code></span>
            </footer>
            <div class="viewer" hidden role="dialog" aria-modal="true" aria-label="Photo viewer">
              <header>
                <span class="where"></span>
                <span class="state"></span>
                <span class="hint">← → to compare · Esc to close</span>
                <button class="close" aria-label="Close">✕</button>
              </header>
              <div class="stage">
                <button class="prev" aria-label="Previous photo">‹</button>
                <img alt="">
                <button class="next" aria-label="Next photo">›</button>
              </div>
              <footer><p class="note"></p><p class="meta"></p></footer>
            </div>
            <script>\(script)</script>
            </body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let script = """
        const $ = (s, el = document) => el.querySelector(s);
        const $$ = (s, el = document) => [...el.querySelectorAll(s)];
        const store = {
          get(k) { try { return localStorage.getItem(k); } catch { return null; } },
          set(k, v) { try { localStorage.setItem(k, v); } catch {} },
        };

        // Filters
        $$('.filters button').forEach(b => b.onclick = () => {
          $$('.filters button').forEach(x => x.classList.toggle('on', x === b));
          const f = b.dataset.f;
          $$('.group').forEach(g => {
            g.hidden = !(f === 'all' || (f === 'moving' && g.dataset.moving === 'true') || (f === 'model' && g.dataset.model === 'true') || (f === 'flagged' && g.dataset.flagged === 'true'));
          });
        });

        // Tile size
        function setSize(size) {
          document.body.dataset.size = size;
          $$('.sizes button').forEach(b => b.classList.toggle('on', b.dataset.size === size));
          store.set('pixelgraph.size', size);
        }
        $$('.sizes button').forEach(b => b.onclick = () => setSize(b.dataset.size));
        setSize(store.get('pixelgraph.size') || 'm');

        // Viewer: click a photo to enlarge, arrows flick through its group.
        const viewer = $('.viewer'), big = $('img', viewer);
        let figures = [], index = 0, opener = null;
        let loading = null;
        function show(i) {
          index = (i + figures.length) % figures.length;
          const fig = figures[index];
          // The tile's copy is already loaded: show it at once, swap in the large one when ready.
          big.src = $('.img img', fig).src;
          const full = new Image();
          loading = full;
          full.onload = () => { if (loading === full) big.src = full.src; };
          full.src = fig.dataset.full;
          $('.where', viewer).textContent = `${fig.closest('.group').dataset.title} · ${index + 1} of ${figures.length}`;
          const state = ['best', 'keep', 'move', 'moved'].find(c => fig.classList.contains(c));
          $('.state', viewer).textContent = { best: '★ Best', keep: 'Keep', move: '✓ Move', moved: 'Moved' }[state];
          $('.state', viewer).className = 'state ' + state;
          $('footer .note', viewer).innerHTML = $('.note', fig).innerHTML;
          $('footer .note', viewer).className = $('.note', fig).className;
          $('footer .meta', viewer).innerHTML = $('.meta', fig).innerHTML;
          $$('.prev, .next', viewer).forEach(b => b.hidden = figures.length < 2);
          // Warm the neighbours so flicking is instant.
          [index + 1, index - 1].forEach(j => { const f = figures[(j + figures.length) % figures.length]; new Image().src = f.dataset.full; });
        }
        function open(fig) {
          figures = $$('figure[data-full]', fig.closest('.group'));
          opener = $('.img', fig);
          viewer.hidden = false;
          document.body.classList.add('viewing');
          show(figures.indexOf(fig));
          $('.close', viewer).focus();
        }
        function close() {
          viewer.hidden = true;
          big.removeAttribute('src');
          document.body.classList.remove('viewing');
          opener?.focus();
        }
        $$('figure[data-full] .img').forEach(b => b.onclick = () => open(b.closest('figure')));
        $('.prev', viewer).onclick = e => { e.stopPropagation(); show(index - 1); };
        $('.next', viewer).onclick = e => { e.stopPropagation(); show(index + 1); };
        $('.close', viewer).onclick = close;
        $('.stage', viewer).onclick = e => { if (e.target === e.currentTarget) close(); };
        document.addEventListener('keydown', e => {
          if (viewer.hidden) return;
          if (e.key === 'Escape') close();
          else if (e.key === 'ArrowRight') show(index + 1);
          else if (e.key === 'ArrowLeft') show(index - 1);
        });
        let touchX = null;
        viewer.addEventListener('touchstart', e => { touchX = e.touches[0].clientX; }, { passive: true });
        viewer.addEventListener('touchend', e => {
          if (touchX === null) return;
          const dx = e.changedTouches[0].clientX - touchX;
          if (Math.abs(dx) > 50) show(index + (dx < 0 ? 1 : -1));
          touchX = null;
        });
        """

    private static let css = """
        :root { --bg:#f5f5f7; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --well:#ececf0;
                --accent:#0071e3; --accent-fill:#0a84ff; --best:#248a3d; --best-fill:#34c759; --warn:#b25000;
                --tile:300px; color-scheme: light dark; }
        @media (prefers-color-scheme: dark) {
          :root { --bg:#000; --card:#1c1c1e; --text:#f5f5f7; --muted:#98989d; --line:#2c2c2e; --well:#111113;
                  --accent:#2997ff; --best:#30d158; --best-fill:#30d158; --warn:#ffb340; }
        }
        body[data-size="s"] { --tile: 200px; }
        body[data-size="m"] { --tile: 300px; }
        body[data-size="l"] { --tile: 460px; }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--text);
               font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
               -webkit-font-smoothing: antialiased; }
        body.viewing { overflow: hidden; }
        main { max-width: 1600px; margin: 0 auto; padding: 40px 32px 120px; }
        .brand { margin: 0; color: var(--muted); font-size: 13px; font-weight: 600; letter-spacing: .02em; }
        h1 { font-size: 40px; letter-spacing: -0.02em; margin: 2px 0 4px; font-weight: 700; }
        .scope { color: var(--muted); margin: 0 0 28px; }
        .stats { display:grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 28px; }
        .stats div { background: var(--card); border-radius: 14px; padding: 16px 18px; }
        .stats b { display:block; font-size: 28px; font-weight: 600; letter-spacing: -0.01em; }
        .stats .accent b { color: var(--accent); }
        .stats span { color: var(--muted); font-size: 13px; }
        nav { display:flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 8px;
              margin-bottom: 24px; position: sticky; top: 0; padding: 12px 0; z-index: 2;
              background: color-mix(in srgb, var(--bg) 85%, transparent);
              backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
        .filters { display:flex; flex-wrap: wrap; gap: 8px; }
        nav button { font: inherit; font-size: 13px; border: 0; border-radius: 999px; padding: 6px 14px;
                     background: var(--card); color: var(--text); cursor: pointer; }
        nav button b { color: var(--muted); font-weight: 500; margin-left: 4px; }
        nav button.on { background: var(--text); color: var(--bg); }
        nav button.on b { color: inherit; opacity: .7; }
        .sizes { display:flex; background: var(--card); border-radius: 999px; padding: 3px; }
        .sizes button { padding: 3px 12px; font-weight: 600; font-size: 12px; background: transparent; }
        .group { background: var(--card); border-radius: 18px; padding: 20px; margin-bottom: 16px; }
        .group header { display:flex; flex-wrap: wrap; align-items: baseline; gap: 6px 10px; margin-bottom: 14px; }
        .group h2 { font-size: 17px; margin: 0; font-weight: 600; }
        .kind, .badge { font-size: 12px; font-weight: 600; padding: 2px 9px; border-radius: 999px;
                background: color-mix(in srgb, var(--accent) 14%, transparent); color: var(--accent); }
        .badge.done { background: color-mix(in srgb, var(--best) 14%, transparent); color: var(--best); }
        .badge.model { background: color-mix(in srgb, var(--warn) 14%, transparent); color: var(--warn); }
        .counts { color: var(--muted); font-size: 13px; margin-left: auto; }
        .counts b { color: var(--accent); font-weight: 600; }
        .grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(min(var(--tile), 100%), 1fr)); gap: 16px; }
        figure { margin: 0; min-width: 0; }
        .img { position: relative; display: block; width: 100%; aspect-ratio: 4 / 3; padding: 0; border: 0;
               border-radius: 12px; overflow: hidden; background: var(--well); cursor: zoom-in; }
        /* Whole frame, never cropped: the difference may be at the edge. */
        .img img { width: 100%; height: 100%; object-fit: contain; display: block; transition: transform .2s ease, opacity .2s ease; }
        .img:hover img { transform: scale(1.02); }
        .img:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
        .best .img { box-shadow: inset 0 0 0 3px var(--best-fill); }
        .move .img img, .moved .img img { opacity: .45; }
        .mark { position: absolute; top: 8px; left: 8px; font-size: 11px; font-weight: 700; letter-spacing: .02em;
                padding: 3px 8px; border-radius: 6px; }
        .mark.best { background: var(--best-fill); color: #04210d; }
        .mark.keep { background: rgba(0,0,0,.55); color: #fff; }
        .mark.moved { background: rgba(0,0,0,.55); color: #ccc; }
        /* Selected to move: the round check from Photos. */
        .check { position: absolute; right: 10px; bottom: 10px; width: 24px; height: 24px; border-radius: 50%;
                 background: var(--accent-fill); color: #fff; font-size: 14px; font-weight: 700; line-height: 22px;
                 border: 1.5px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.3); }
        .missing { display:grid; place-items:center; height:100%; color: var(--muted); font-size: 13px; }
        figcaption { padding: 8px 2px 0; }
        .note { margin: 0; font-size: 13px; font-weight: 500; }
        .note.best { color: var(--best); }
        .note.move { color: var(--accent); }
        .note .why { color: var(--warn); }
        .note.muted { color: var(--muted); }
        .meta { margin: 2px 0 0; font-size: 12px; color: var(--muted); }
        .empty { color: var(--muted); text-align: center; padding: 64px 0; }
        .bar { position: fixed; left: 0; right: 0; bottom: 0; display: flex; flex-wrap: wrap; gap: 4px 16px;
               justify-content: space-between; align-items: center; padding: 14px 32px; font-size: 14px;
               background: color-mix(in srgb, var(--card) 88%, transparent); border-top: 1px solid var(--line);
               backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
        .bar b { color: var(--accent); }
        .bar .hint { color: var(--muted); font-size: 13px; }
        .bar code { font: 12px ui-monospace, SFMono-Regular, monospace; background: var(--well); padding: 2px 6px; border-radius: 5px; }

        .viewer { position: fixed; inset: 0; z-index: 10; display: grid; grid-template-rows: auto 1fr auto;
                  background: rgba(0,0,0,.97); color: #f5f5f7; }
        .viewer[hidden] { display: none; }
        .viewer header { display:flex; align-items:center; gap: 12px; padding: 14px 20px; font-size: 14px; }
        .viewer .where { font-weight: 600; }
        .viewer .state { font-size: 12px; font-weight: 700; padding: 2px 8px; border-radius: 6px; background: rgba(255,255,255,.14); }
        .viewer .state.best { background: #30d158; color: #04210d; }
        .viewer .state.move { background: #0a84ff; color: #fff; }
        .viewer .hint { color: #98989d; font-size: 12px; margin-left: auto; }
        .viewer .close { background: rgba(255,255,255,.12); color: #fff; border: 0; border-radius: 999px;
                         width: 32px; height: 32px; font-size: 14px; cursor: pointer; }
        .viewer .stage { position: relative; min-height: 0; }
        /* Pinned to the stage so tall portraits shrink to fit instead of overflowing it. */
        .viewer img { position: absolute; inset: 0 72px; width: calc(100% - 144px); height: 100%; object-fit: contain; }
        .viewer .prev, .viewer .next { position: absolute; z-index: 1; top: 50%; transform: translateY(-50%);
               width: 48px; height: 48px; border-radius: 999px; border: 0; cursor: pointer;
               background: rgba(255,255,255,.12); color: #fff; font-size: 28px; line-height: 1; }
        .viewer .prev:hover, .viewer .next:hover, .viewer .close:hover { background: rgba(255,255,255,.22); }
        .viewer .prev { left: 14px; }
        .viewer .next { right: 14px; }
        .viewer footer { padding: 12px 20px 18px; text-align: center; }
        .viewer footer .note { font-size: 15px; color: #f5f5f7; }
        .viewer footer .note.best { color: #30d158; }
        .viewer footer .note.move { color: #64a8ff; }
        .viewer footer .meta { color: #98989d; font-size: 13px; }

        @media (max-width: 700px) {
          main { padding: 28px 16px 140px; }
          h1 { font-size: 30px; }
          .stats { grid-template-columns: repeat(2, 1fr); }
          .group { padding: 14px; }
          .counts { margin-left: 0; }
          .bar { padding: 12px 16px; }
          .viewer img { inset: 0 8px; width: calc(100% - 16px); }
          .viewer .prev, .viewer .next, .viewer .hint { display: none; }
        }
        """
}
