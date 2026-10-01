# PixelGraph

Find near-identical photos, keep the best, and move the rest to Duplicates — on your Mac, with nothing uploaded and nothing deleted.

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

- **Groups:** arrows to move, Enter or click to open, Space to keep or move a whole group, `v` for filmstrips.
- **Inside a group:** Space switches a photo between Keep and Move, `b` marks another best, `r` gives a reason, Enter or click to enlarge, ← → to compare.
- **`m` moves** the selection after you confirm. **`u` undoes** the last move.

In iTerm2 photos are shown as real images; other true-colour terminals get colour-block previews.

### Where moved photos go

- **Apple Photos:** into a "PixelGraph Duplicates" album, and out of the album you scanned. They stay in your library until you delete them from that album.
- **Folders and drives:** into a "PixelGraph Duplicates" folder inside the scanned folder, keeping the folder layout. RAW+JPEG pairs and `.xmp`/`.aae` sidecars move together.

### iCloud

With **Optimize Mac Storage** on, most originals live in iCloud. PixelGraph groups photos using the previews already on your Mac, then downloads only the photos that ended up in a group, to judge sharpness and faces properly. iCloud Drive files are fingerprinted from their thumbnails and downloaded the same way. `--offline` never downloads.

### Big libraries

Scan in parts — an album, a month, a folder. Results are cached, so rescans are quick and a stopped scan picks up where it left off.

### Tuning

`--moment-threshold` (default 0.5) and `--moment-window` (600 s) control how alike shots taken close together must be; `--scene-threshold` (0.3) does the same for shots any time apart. Lower is stricter.

Data lives in `~/Library/Application Support/PixelGraph/`.

## License

MIT
