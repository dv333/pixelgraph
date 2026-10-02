# PixelGraph

Find near-identical photos, keep the best, and move the rest to PGDuplicates or delete them — on your Mac, with nothing uploaded.

PixelGraph groups retakes, bursts, portraits where only the expression changes, copies and edits, the same scene revisited, and repeated screenshots. It picks the best shot in each group, flags photos with closed eyes or blocked faces, and pre-selects everything else to move. You confirm, it moves, and you can undo.

Works with **Apple Photos and iCloud Photos**, **folders**, **external drives** and **iCloud Drive**.

Requires macOS 27 on Apple Silicon. Apple Intelligence makes it better (close calls, eyes and faces) but isn't required.

## Install

```bash
brew install dv333/tap/pixelgraph
```

Or build it yourself with Xcode 27:

```bash
swift build -c release
cp .build/release/pixelgraph /usr/local/bin/
```

## Use

```bash
pixelgraph
```

In iTerm2, Ghostty, kitty and WezTerm, PixelGraph opens with a short title: a field of out-of-focus lights racks into focus and becomes the name. Any key skips it; `--no-intro` or `PIXELGRAPH_NO_INTRO=1` turns it off.

The start screen keeps to what you'd do next. At the top, **Continue reviewing** picks up the review you're in the middle of, with how far it's got. **New scan** has Last 7 days, Last 30 days and Since your last scan, then **Albums ›**, **Months and years ›** and **Folders and drives ›** (iCloud Drive, Pictures, drives, "Back to …" the folder you were last in, or any other folder), each a screen of its own. **Pinned** folders come next (P pins the highlighted folder, P again unpins), then **Recent**: your last five scans, each once. Every row lines up in three columns: what it is, how many photos, and how far it got (`Scanned Oct 2`, or in green `Reviewed Oct 2`, `Moved 34 · Oct 2`); rows that open another screen end in ›. Library parts are named the way you'd say them: "December 2025", "Jun – Aug 2024", "Since Sep 26".

PixelGraph scans with one bar for the whole scan; when it's done, Enter opens the review (Esc keeps it for later, under "Continue reviewing"). If a scan took a while, the terminal rings and, where it can, shows a notification. On the months screen, each month has a bar for how many photos it holds; Space ticks a month (or a whole year), X ticks every month from the last one you ticked, C clears the ticks, and Enter scans just the ticked months, even ones far apart. Ticks are kept for next time. Choosing something that's been scanned before says so, and Enter scans it again. When photos have waited long enough in PGDuplicates or PGJunk, "Empty PGDuplicates and PGJunk…" appears near the bottom: it shows what would go and deletes only on D. Press `,` for Settings and `?` for the keys on any screen.

```
pixelgraph scan --album "Japan 2025"         # an Apple Photos album
pixelgraph scan --from 2024-06 --to 2024-08  # part of your library
pixelgraph scan --folder /Volumes/T7/DCIM    # a folder, drive or iCloud Drive folder
pixelgraph review                            # pick up where you left off
pixelgraph report                            # the last scan as a web page
pixelgraph undo                              # put back the last move
pixelgraph eval                              # how PixelGraph did against your reviews
```

### Reviewing

Every photo is **Keep** or **Move**. The best shot in each group is kept (★); everything else starts selected to move (→), with the reason shown — "blurrier", "near-exact copy", "eyes closed". Most of the time you only confirm: on the groups screen, A accepts every group PixelGraph is sure about (exact copies, and shots well behind a clean best) and takes you to the first one that needs a look. The move button shows how much the selection takes up.

One key means one thing on every screen, and keys set a state rather than toggling it, so pressing twice can't undo what you meant:

| Key | Does |
|---|---|
| ← → ↑ ↓ | move around (mouse wheel and Page Up/Down scroll the groups) |
| Space | look closer, like Quick Look · again to go back |
| Enter | open · confirm |
| Esc | back · cancel — never changes anything; leaving the review asks first |
| K | keep this photo (on a group: keep them all) |
| X | move this photo (on a group: all but the best) |
| B | make it the best ★ |
| A | on the groups: accept every clear group as PixelGraph chose · in a group: select every photo, and the next K, X, R or M applies to all of them (Esc clears) |
| R | say why it's moving |
| C | compare two photos side by side: ← → change the candidate, ↑ pins it |
| Z | while looking closer or comparing: zoom in on the faces, to check eyes · again for the whole photo |
| O | show the photo in Finder (Photos library photos open in Photos) |
| M | move the selection to PGDuplicates, or D in the sheet (the red button) to delete it — always asks first |
| Tab | switch between Duplicates (junk groups at the end) and Documents |
| ] [ | the next or previous group still to review (no ✓) |
| 1–9 | in a group: go straight to that photo |
| I | in a group: show or hide the tags, time and scores under each photo |
| Home End | the first or last group, or photo |
| U | undo the last change or move |
| ? | all the keys |
| Q | quit — asks first, here and on the start screen; everything is saved as you go |

In iTerm2, WezTerm, kitty and Ghostty photos are shown as real images; other true-colour terminals get colour-block previews. Photos selected to move are shown muted, not darkened, so they're still easy to judge. Clicking a sheet's button does what it says; clicking outside a sheet closes it.


**Editing.** `e` opens the highlighted photo in Photos' editor (after `a`, every photo in the group goes into a "PG Edit" album in Photos: Return edits, → goes to the next). Photos from folders and drives open in Preview. When you come back, the previews show your edit. Opening straight into Edit presses Return in Photos for you, which needs your terminal allowed in System Settings → Privacy & Security → Accessibility; without it the photo is just shown and you press Return. Edits in Photos can always be undone with Image → Revert to Original.
### Documents

Receipts, bills, forms, letters, IDs, tickets, notes, whiteboards, screenshots and photos of screens are sorted onto their own **Documents** tab (press Tab on the groups screen). Each is named — "Pier 39 Café receipt", "Form · I-797C notice" — from its text, read on your Mac. Copies of a document are matched by **what they say**, not just how they look, so two forms from the same template with different names are never treated as duplicates. The best copy is filed in **PGDocuments**; extra copies go to Duplicates. On that tab, `d` files a copy, `k` keeps it where it is, `x` marks it as a copy.

### Descriptions and scene tags

Photos in groups get scene tags from Vision ("beach, rocks"), shown under each photo and in the enlarged view. Written descriptions are made only when you move, for the photos you keep (see below). Choose what runs each time from the home screen, or use `--no-documents` and `--no-describe`.

### Where moved photos go

When you press M, PixelGraph asks what to do with the copies: **Enter** moves them to PGDuplicates, **D** deletes them. Documents are always filed in PGDocuments.

- **Apple Photos, move:** into a "PGDuplicates" album, and out of the album you scanned. They stay in your library until you delete them from that album. Albums Photos won't let apps change (synced from your Mac, shared) keep their photos; PixelGraph tells you when that happens.
- **Apple Photos, delete:** to Recently Deleted for 30 days (macOS asks first). Recover them there; `pixelgraph undo` can't.
- **Folders and drives, move:** into a "PGDuplicates" (or "PGDocuments") folder inside the scanned folder, keeping the folder layout. RAW+JPEG pairs and `.xmp`/`.aae` sidecars move together.
- **Folders and drives, delete:** to the Trash, with their RAW and sidecar files; undo puts them back.

Moves made before the rename went to "PixelGraph Duplicates"; that album or folder is left as it is, and undo still finds them.

### How it decides

**Grouping.** Every photo gets a Vision fingerprint, a tiny copy hash and quality measures from the preview already on your Mac. Two photos can group when their fingerprints are close. How close is allowed eases smoothly from loose (shots seconds apart) to strict (shots days apart) instead of jumping at a cutoff, and is tightened when the number of people differs. Copies and re-saves match by hash anywhere, any time. Photos taken more than 2 km apart never group unless they're copies. Close calls between photos taken apart in time are lined up with Vision's image registration and kept apart if the pixels don't match. Groups form by average linkage, so a burst that pans stays together without a chain of different shots drifting into one group.

**Best shot and rejects.** Sharpness is measured where it matters: on the faces, or on the sharpest part of the frame net of noise, so a portrait with a soft background isn't called blurry and a noisy night shot isn't called sharp. Exposure counts crushed shadows and blown highlights. Rejects are judged against the other shots in the group: eyes shut when the same person has them open in another frame, a head turned away, the subject much softer than in the sharpest shot (motion blur or missed focus), poor exposure, a smudged lens. Apple Intelligence, when available, still checks faces and breaks close calls.

**Junk.** Photos with no lookalike can still be worth throwing away, and appear after the duplicate groups, one group per reason (all the blurry ones together, all the old screenshots together), all selected to move, and move to their own PGJunk album or folder: accidental shots (the floor, a ceiling, a pocket, nothing in the frame), blurry or crooked ones, nearly black or blown-out ones, ones taken through a smudged lens, screenshots older than 30 days (`--screenshot-days`), and small images forwarded from chats. One strong sign is enough (nearly black, smudged, among the blurriest 5% of the scan and poorly rated, an old screenshot); otherwise two weaker ones must agree, and Apple Intelligence, when available, gets the last word and spares anything worth keeping. Having no face is never a reason. The extra checks only run on photos that already look weak, and are remembered. The nightly run never moves junk on its own. `--no-junk` turns it off.

**Learning from you.** A group counts as reviewed (✓) once you act on it, once nothing in it is left to do, or once you've looked at every photo in it; just opening it doesn't count. Every reviewed group is remembered (`decisions.json` in PixelGraph's data folder). After 10 reviewed groups, the weights behind the best-shot pick shift toward the shots you choose. `pixelgraph eval` shows how often PixelGraph's pick was your ★, how often its reject flags were right, and how many groups you kept whole.

### Descriptions for the photos you keep

When you move a group's extra copies, the photos you keep get a title, a caption and keywords, so searching Photos (or Spotlight, for folders) for "sunset" or "beach" finds them. Apple's on-device model writes the title and caption, leaving people out; Vision adds scene keywords. Without Apple Intelligence only keywords are written.

- **Apple Photos:** written through the Photos app, since apps can't set these directly. The first time, macOS asks to let your terminal control Photos.
- **Folders and drives:** written into the file's own metadata (XMP) for JPEG, HEIC, PNG and TIFF; the image itself isn't touched.

New text goes after anything already there ("Mom's birthday · Candles on a chocolate cake"), and undo puts back what was there before. A progress bar shows while it runs.

### Use it from Claude, ChatGPT or Codex

`pixelgraph mcp` runs PixelGraph as an MCP server: an assistant can scan, read the groups, look at the photos, change a pick, move and undo. Install the binary somewhere stable first, e.g. `swift build -c release && cp .build/release/pixelgraph /usr/local/bin/`.

- **Claude Desktop:** add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
  ```json
  { "mcpServers": { "pixelgraph": { "command": "/usr/local/bin/pixelgraph", "args": ["mcp"] } } }
  ```
- **Claude Code:** `claude mcp add pixelgraph -- /usr/local/bin/pixelgraph mcp`
- **ChatGPT desktop in Codex mode, or the Codex CLI:** add to `~/.codex/config.toml`:
  ```toml
  [mcp_servers.pixelgraph]
  command = "/usr/local/bin/pixelgraph"
  args = ["mcp"]
  ```
- **ChatGPT on the web:** it only reaches servers on the internet, so run `pixelgraph mcp --http`, put a tunnel in front (`cloudflared tunnel --url http://127.0.0.1:8765`) and add a connector in ChatGPT's Developer mode with the URL it prints, secret code included. Anyone with that URL can reach your photos, so keep it private; deleting is switched off on this connection.

Then ask, for example, "scan my photos from last month and show me the close calls". The assistant asks for a dry run before moving; it deletes only when you say so (`--no-trash` switches deleting off completely). Photo access belongs to the app that starts PixelGraph, so allow Claude or Codex when macOS asks. Thumbnails an assistant looks at are sent to that assistant's service.

### Nightly clean-up

`pixelgraph schedule --at 02:00 --now` (or "Run every night" in Settings) runs `pixelgraph auto` every night through launchd. It scans the last 30 days into its own workspace (never your review in progress), moves only the clear cases to PGDuplicates (extra copies of the same picture, and burst shots well behind the best or flagged, when the best is clean), never deletes, caps a night at 300 photos, and sends a notification. Close calls wait for you (`pixelgraph review --nightly`) or for an assistant: add `--assistant claude` or `--assistant codex` to let Claude Code or Codex settle them with deleting switched off. `--now` runs it once straight away so macOS can ask for Photos access while you're there. `pixelgraph schedule --off` stops it; `pixelgraph undo` puts back the last move.

### Fully automatic, with a local model

A vision model running on your Mac through [Ollama](https://ollama.com) can settle the close calls and borderline junk the nightly run would otherwise leave for you. Nothing leaves the Mac.

1. `ollama pull qwen2.5vl:32b` (about 21 GB; with less than 32 GB of memory use `qwen2.5vl:7b`).
2. Check it against your own past decisions first: `pixelgraph eval --judge-model qwen2.5vl:32b`. It shows how often the model's pick was your ★ and, more importantly, how often the nightly rule would have matched you, and says whether it's safe enough.
3. `pixelgraph schedule --at 02:00 --judge-model qwen2.5vl:32b`.

The model moves photos only when it picks the same shot as PixelGraph with at least 85% confidence (`--judge-confidence`); anything it says is a different moment worth keeping stays. Junk moves to PGJunk only when the model also calls it junk that surely. Everything else still waits for you. Nothing is deleted: once a month, when photos have waited 30 days in PGDuplicates or PGJunk, a notification suggests `pixelgraph empty`, which asks before sending them to Recently Deleted or the Trash.

### OpenCode, step by step

[OpenCode](https://opencode.ai) is an open-source assistant for the terminal that works with any model, including ones running on your Mac. Hooked to PixelGraph, you can ask it to tidy your photos in plain words, and the nightly run can hand it the close calls.

**1. Install PixelGraph where OpenCode can find it.**
```bash
cd pixelgraph && git pull && swift build -c release
sudo cp .build/release/pixelgraph /usr/local/bin/
pixelgraph --version
```

**2. Install OpenCode.**
```bash
curl -fsSL https://opencode.ai/install | bash   # or: npm i -g opencode-ai
opencode --version
```

**3. Pick a model.** It has to call tools, and to judge photos it has to see them.
- Fully local (nothing leaves the Mac): install [Ollama](https://ollama.com) (`brew install ollama`), then
  ```bash
  ollama pull qwen3-vl:32b     # 48 GB+ of memory; on 16–32 GB use qwen3-vl:8b
  OLLAMA_CONTEXT_LENGTH=32768 ollama serve
  ```
  The longer context matters: OpenCode's instructions and PixelGraph's tool list don't fit in Ollama's small default. To keep it running in the background instead, `brew services start ollama` after `launchctl setenv OLLAMA_CONTEXT_LENGTH 32768`.
- Or a cloud model: run `opencode auth login` and choose a provider. The thumbnails it looks at go to that provider.

**4. Tell OpenCode about PixelGraph (and Ollama).** Create `~/.config/opencode/opencode.json`:
```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (this Mac)",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": { "qwen3-vl:32b": { "name": "Qwen3-VL 32B" } }
    }
  },
  "model": "ollama/qwen3-vl:32b",
  "mcp": {
    "pixelgraph": { "type": "local", "command": ["/usr/local/bin/pixelgraph", "mcp", "--no-trash"], "enabled": true }
  }
}
```
Using a cloud model? Leave out `provider` and `model`. `--no-trash` means the assistant can move photos to PGDuplicates but never delete; drop it if you want it able to delete when you ask.

**5. Allow Photos.** Photos access belongs to the app that starts PixelGraph. Run `opencode` once from Terminal (or iTerm) and ask it to scan an album; when macOS asks whether Terminal may access Photos, allow it. Folders need no permission.

**6. Use it.** Start `opencode` in any folder and ask, for example:
- "Use pixelgraph to scan my photos from last month and tell me what it found."
- "Show me the close calls one group at a time and pick the best."
- "Do a dry run of moving the duplicates, then move them."
- "Undo that."
- "Show me group g3." OpenCode can't show pictures in its chat, so PixelGraph opens its own review on that group: in iTerm2 as a pane beside OpenCode (it closes when you leave the review), elsewhere in a new Terminal window. Keep or move photos there; the assistant sees your changes. The first time, macOS asks whether pixelgraph may control iTerm2: allow it. (`pixelgraph review --group g3` does the same by hand.)

To check it's connected, ask "which pixelgraph tools do you have?": it should list scan, list_groups, show_photos, move and the rest.

**7. Let it work every night.** In `pixelgraph settings`, under Nightly clean-up, switch on "Run every night" and set "Then ask" to `opencode` (or run `pixelgraph schedule --assistant opencode --now`). Each night PixelGraph moves the clear duplicates itself, then runs `opencode run` with its tools added and deleting switched off to settle the close calls, using the model in your OpenCode config. To have the local model double-check too, set "Vision model" under Local AI (e.g. `qwen3-vl:32b`), after trying it with `pixelgraph eval --judge-model qwen3-vl:32b`.

**8. Check what happened.** `~/Library/Application Support/PixelGraph/nightly/auto.log` has each night's output, a notification sums it up, `pixelgraph review --nightly` shows what's left and `pixelgraph undo` puts back the last move. Nothing is deleted until you run `pixelgraph empty`, which asks first.

**If something's off:** "can't reach Ollama": start `ollama serve`. The model doesn't use the tools: give it the longer context (step 3) or use a bigger model. "No access to Photos": step 5, or System Settings → Privacy & Security → Photos.

### iCloud

With **Optimize Mac Storage** on, most originals live in iCloud. PixelGraph groups photos using the previews already on your Mac, then downloads only the photos that ended up in a group, to judge sharpness and faces properly. iCloud Drive files are fingerprinted from their thumbnails and downloaded the same way. `--offline` never downloads.

### Big libraries

Scan in parts — an album, a month, a folder. Results are cached, so rescans are quick and a stopped scan picks up where it left off.

### Settings

Press `,` on the home screen (or run `pixelgraph settings`) to change how PixelGraph works. ↑↓ choose, ←→ change, Enter types a value, `d` sets one back to its default, and the last row, “Set every setting back to its default”, sets them all. Changes show in amber with a * until you press `s` to save; leaving with unsaved changes asks whether to save or discard them. A blue ● marks what differs from the default. In terminals that show real photos, highlighting Font shows the opening title in that font. `pixelgraph settings --list` prints them all.

| Section | Setting | Default |
|---|---|---|
| Lookalikes | Shots taken together (how different they may look) | 0.50 |
| | Easing over | 10 min |
| | Shots any time apart | 0.30 |
| | Different places (never lookalikes beyond) | 2 km |
| | Pixel check (close calls must line up this well) | 0.50 |
| Picking the best | Apple Intelligence | On |
| | Stay offline (never download from iCloud) | Off |
| Sorting | Sort documents · Tag scenes | On · On |
| Junk | Look for junk | On |
| | Blurry means the blurriest | 15% |
| | Crooked from | 6° |
| | Old screenshots after | 30 days |
| | Find accidental · blurry · crooked · bad exposure · smudged · old screenshots · forwarded · low quality | all On |
| Moving | Describe kept photos | On |
| Display | Photos | auto (iterm, kitty, blocks) |
| | Theme | auto (light, dark) |
| | Opening title | On |
| | Font (opening title, report headings) | SF Mono (SF Pro, Avenir Next, Futura, New York) |
| Nightly clean-up | Run every night · At | Off · 02:00 |
| | Photos from the last · Move at most | 30 days · 300 |
| | Then ask (assistant) | none (claude, codex, opencode) |
| | Remind to empty after | 30 days |
| Local AI (Ollama) | Vision model | off |
| | Must be this sure | 0.85 |
| | Ollama at | http://localhost:11434 |

A flag on the command line wins for that one run, e.g. `pixelgraph scan --folder ~/Pictures/Trip --moment-threshold 0.4 --no-junk`.

Data lives in `~/Library/Application Support/PixelGraph/`: `pixelgraph.db` (SQLite) keeps your settings, recent scans, pinned folders, ticked months, where you were and each place's progress; `index.sqlite` is only a cache of photo measurements and can be deleted.

## License

MIT
