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
| M | move the selection to PGDuplicates, or D in the sheet to delete it — always asks first |
| U | undo the last change or move |
| ? | all the keys |
| Q | quit — everything is saved as you go |

In iTerm2 photos are shown as real images; other true-colour terminals get colour-block previews.

### Documents

Receipts, bills, forms, letters, IDs, tickets, notes, whiteboards, screenshots and photos of screens are sorted onto their own **Documents** tab (press Tab on the groups screen). Each is named — "Pier 39 Café receipt", "Form · I-797C notice" — from its text, read on your Mac. Copies of a document are matched by **what they say**, not just how they look, so two forms from the same template with different names are never treated as duplicates. The best copy is filed in **PGDocuments**; extra copies go to Duplicates. On that tab, `d` files a copy, `k` keeps it where it is, `x` marks it as a copy.

### Descriptions and scene tags

Photos in groups get a one-line description from Apple's on-device model ("Family posing on rocks by the ocean") and scene tags from Vision ("beach, rocks"), shown under each photo and in the enlarged view. Choose what runs each time from the home screen, or use `--no-documents` and `--no-describe`.

### Where moved photos go

When you press M, PixelGraph asks what to do with the copies: **Enter** moves them to PGDuplicates, **D** deletes them. Documents are always filed in PGDocuments.

- **Apple Photos, move:** into a "PGDuplicates" album, and out of the album you scanned. They stay in your library until you delete them from that album. Albums Photos won't let apps change (synced from your Mac, shared) keep their photos; PixelGraph tells you when that happens.
- **Apple Photos, delete:** to Recently Deleted for 30 days (macOS asks first). Recover them there; `pixelgraph undo` can't.
- **Folders and drives, move:** into a "PGDuplicates" (or "PGDocuments") folder inside the scanned folder, keeping the folder layout. RAW+JPEG pairs and `.xmp`/`.aae` sidecars move together.
- **Folders and drives, delete:** to the Trash, with their RAW and sidecar files; undo puts them back.

Moves made before the rename went to "PixelGraph Duplicates"; that album or folder is left as it is, and undo still finds them.

### Descriptions for the photos you keep

When you move a group's extra copies, the photos you keep get a title, a caption and keywords, so searching Photos (or Spotlight, for folders) for "sunset" or "beach" finds them. Apple's on-device model writes the title and caption, leaving people out; Vision adds scene keywords. Without Apple Intelligence only keywords are written.

- **Apple Photos:** written through the Photos app, since apps can't set these directly. The first time, macOS asks to let your terminal control Photos.
- **Folders and drives:** written into the file's own metadata (XMP) for JPEG, HEIC, PNG and TIFF; the image itself isn't touched.

New text goes after anything already there ("Mom's birthday · Candles on a chocolate cake"), and undo puts back what was there before. A progress bar shows while it runs.

### iCloud

With **Optimize Mac Storage** on, most originals live in iCloud. PixelGraph groups photos using the previews already on your Mac, then downloads only the photos that ended up in a group, to judge sharpness and faces properly. iCloud Drive files are fingerprinted from their thumbnails and downloaded the same way. `--offline` never downloads.

### Big libraries

Scan in parts — an album, a month, a folder. Results are cached, so rescans are quick and a stopped scan picks up where it left off.

### Tuning

`--moment-threshold` (default 0.5) and `--moment-window` (600 s) control how alike shots taken close together must be; `--scene-threshold` (0.3) does the same for shots any time apart. Lower is stricter.

Data lives in `~/Library/Application Support/PixelGraph/`.

## License

MIT
