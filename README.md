# PixelGraph

Find near-identical photos, keep the best, and move the rest to Duplicates — on your Mac, with nothing uploaded and nothing deleted for good.

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

Choose where your photos are — an album, a month of your library, a folder, a drive or iCloud Drive — and PixelGraph scans it, then opens the review.

```
pixelgraph scan --album "Japan 2025"         # an Apple Photos album
pixelgraph scan --from 2024-06 --to 2024-08  # part of your library
pixelgraph scan --folder /Volumes/T7/DCIM    # a folder, drive or iCloud Drive folder
pixelgraph review                            # pick up where you left off
pixelgraph report                            # the last scan as a web page
pixelgraph undo                              # put back the last move
```

### Reviewing

Every photo is **Keep** or **Move**. The best shot in each group is kept (★); everything else starts selected to move, with the reason shown — "blurrier", "near-exact copy", "eyes closed". Most of the time you only confirm.

One key means one thing on every screen, and keys set a state rather than toggling it, so pressing twice can't undo what you meant:

| Key | Does |
|---|---|
| ← → ↑ ↓ | move around (mouse wheel and Page Up/Down scroll the groups) |
| Space | look closer, like Quick Look · again to go back |
| Enter | open · confirm |
| Esc | back · cancel — never changes anything |
| K | keep this photo (on a group: keep them all) |
| X | move this photo (on a group: all but the best) |
| B | make it the best ★ |
| R | say why it's moving |
| C | compare two photos side by side: ← → change the candidate, ↑ pins it |
| M | move the selection to Duplicates — always asks first |
| U | undo the last change or move |
| ? | all the keys |
| Q | quit — everything is saved as you go |

In iTerm2 photos are shown as real images; other true-colour terminals get colour-block previews.

### Documents

Receipts, bills, forms, letters, IDs, tickets, notes, whiteboards, screenshots and photos of screens are sorted onto their own **Documents** tab (press Tab on the groups screen). Each is named — "Pier 39 Café receipt", "Form · I-797C notice" — from its text, read on your Mac. Copies of a document are matched by **what they say**, not just how they look, so two forms from the same template with different names are never treated as duplicates. The best copy is filed in **PGDocuments**; extra copies go to Duplicates. On that tab, `d` files a copy, `k` keeps it where it is, `x` marks it as a copy.

### Descriptions and scene tags

Photos in groups get a one-line description from Apple's on-device model ("Family posing on rocks by the ocean") and scene tags from Vision ("beach, rocks"), shown under each photo and in the enlarged view. Choose what runs each time from the home screen, or use `--no-documents` and `--no-describe`.

### Where moved photos go

- **Apple Photos, album scans:** into a "PixelGraph Duplicates" album (documents: "PGDocuments"), and out of the album you scanned. They stay in your library until you delete them from that album. Albums Photos won't let apps change (synced from your Mac, shared) keep their photos; PixelGraph tells you when that happens.
- **Apple Photos, library scans:** duplicates are added to "PixelGraph Duplicates" and deleted from the library, so they go to Recently Deleted for 30 days (macOS asks first). Recover them there; `pixelgraph undo` can't. Documents stay in the library, in "PGDocuments".
- **Folders and drives:** into a "PixelGraph Duplicates" (or "PGDocuments") folder inside the scanned folder, keeping the folder layout. RAW+JPEG pairs and `.xmp`/`.aae` sidecars move together.

### iCloud

With **Optimize Mac Storage** on, most originals live in iCloud. PixelGraph groups photos using the previews already on your Mac, then downloads only the photos that ended up in a group, to judge sharpness and faces properly. iCloud Drive files are fingerprinted from their thumbnails and downloaded the same way. `--offline` never downloads.

### Big libraries

Scan in parts — an album, a month, a folder. Results are cached, so rescans are quick and a stopped scan picks up where it left off.

### Tuning

`--moment-threshold` (default 0.5) and `--moment-window` (600 s) control how alike shots taken close together must be; `--scene-threshold` (0.3) does the same for shots any time apart. Lower is stricter.

Data lives in `~/Library/Application Support/PixelGraph/`.

## License

MIT
