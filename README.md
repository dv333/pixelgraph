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

Choose where your photos are — an album, a month of your library, a folder, a drive or iCloud Drive — and PixelGraph scans it, then opens the review. On the months screen, Space ticks a month (or a whole year), X ticks every month from the last one you ticked, and Enter scans just the ticked months, even ones far apart.

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

Every photo is **Keep** or **Move**. The best shot in each group is kept (★); everything else starts selected to move, with the reason shown — "blurrier", "near-exact copy", "eyes closed". Most of the time you only confirm.

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
| R | say why it's moving |
| C | compare two photos side by side: ← → change the candidate, ↑ pins it |
| O | show the photo in Finder (Photos library photos open in Photos) |
| M | move the selection to PGDuplicates, or D in the sheet to delete it — always asks first |
| Tab | switch between Duplicates, Documents and Junk |
| U | undo the last change or move |
| ? | all the keys |
| Q | quit — asks first; everything is saved as you go |

In iTerm2 photos are shown as real images; other true-colour terminals get colour-block previews.

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

**Junk.** Photos with no lookalike can still be worth throwing away, and go on a third tab, Junk, all selected to move: accidental shots (the floor, a ceiling, a pocket, nothing in the frame), blurry or crooked ones, nearly black or blown-out ones, ones taken through a smudged lens, screenshots older than 30 days (`--screenshot-days`), and small images forwarded from chats. One strong sign is enough (nearly black, smudged, among the blurriest 5% of the scan and poorly rated, an old screenshot); otherwise two weaker ones must agree, and Apple Intelligence, when available, gets the last word and spares anything worth keeping. Having no face is never a reason. The extra checks only run on photos that already look weak, and are remembered. The nightly run never moves junk on its own. `--no-junk` turns it off.

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

`pixelgraph schedule --at 02:00 --now` runs `pixelgraph auto` every night through launchd. It scans the last 30 days into its own workspace (never your review in progress), moves only the clear cases to PGDuplicates (extra copies of the same picture, and burst shots well behind the best or flagged, when the best is clean), never deletes, caps a night at 300 photos, and sends a notification. Close calls wait for you (`pixelgraph review --nightly`) or for an assistant: add `--assistant claude` or `--assistant codex` to let Claude Code or Codex settle them with deleting switched off. `--now` runs it once straight away so macOS can ask for Photos access while you're there. `pixelgraph schedule --off` stops it; `pixelgraph undo` puts back the last move.

### iCloud

With **Optimize Mac Storage** on, most originals live in iCloud. PixelGraph groups photos using the previews already on your Mac, then downloads only the photos that ended up in a group, to judge sharpness and faces properly. iCloud Drive files are fingerprinted from their thumbnails and downloaded the same way. `--offline` never downloads.

### Big libraries

Scan in parts — an album, a month, a folder. Results are cached, so rescans are quick and a stopped scan picks up where it left off.

### Tuning

`--moment-threshold` (default 0.5) and `--moment-window` (600 s) control how alike shots taken close together must be; `--scene-threshold` (0.3) does the same for shots any time apart. Lower is stricter.

Data lives in `~/Library/Application Support/PixelGraph/`.

## License

MIT
