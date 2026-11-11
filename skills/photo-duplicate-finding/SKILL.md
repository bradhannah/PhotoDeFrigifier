---
name: photo-duplicate-finding
description: Find duplicate and near-duplicate photos and videos across or within libraries (Amazon, Google Takeout, Apple Photos, folders, backups), pick which copy to keep, and set aside low-value junk, without deleting anything. Covers exact hashes, same-moment matching, Apple's fingerprint, perceptual hashes with tested thresholds, positive controls, keeper rules and visual review. Use this whenever someone asks to dedupe, find duplicates, merge photo libraries, compare two photo collections, check what's already in Apple Photos, or clean out screenshots and junk images, even if they only say "make sure I don't get doubles".
---

# Finding duplicate photos

These methods come from a migration of an Amazon library (about 7,900 media files) into an Apple Photos library of 4,795 items. Four independent checks ended with 5,030 imports and no duplicates.

## Principles

- **Never delete; file away.** Move duplicates with a same-volume rename into a `duplicates/<kind>/` folder that keeps the original relative paths.
  - Log every move to a CSV, and give the mover `plan`, `move` and `undo` modes.
  - Carry the loser's metadata along in a `_metadata.jsonl` file: cloud IDs, People names, albums. Then nothing is lost if the keeper needs it.
  - Final deletion is the user's call, made later and explicitly.
- **Rank evidence and automate only the certain tiers.** Everything else goes to the user as pictures, never as a bare list.
- **Never match on filename alone.** `IMG_1597` recurs across phones and years. In one library 287 names were shared by different photos, and only 5 of those were real copies.
- **Prove the detector with a positive control.** Run the check on a set of known duplicates.
  - In one control, Apple's own fingerprint caught 27 of 29. The 2 it missed were a re-rendered file and an edited copy, which only the visual check caught.
  - Without a control you can't tell "no duplicates" from "detector blind".
- **Exclude near-blank images** (grayscale stddev under 8) from visual matching, because they match everything.

## The evidence ladder, most certain first

1. **Same bytes.** Use SHA-256, or MD5 where a provider already reports it (Amazon does). This is automatic.
   - Within one source, keep one copy and record `keep_id` against the others.
   - Provider-reported MD5 identifies *their* copy. Measure local bytes yourself before calling two files identical.
2. **Same moment, same camera** (the "obvious duplicate" rule, for HEIC-vs-JPEG copies and the like). It counts only when **all four** of these hold:
   1. The same capture second from a date embedded in the file (EXIF DateTimeOriginal, CreateDate or QuickTime). Never use a date guessed from a filename. If both files record sub-seconds, the first two digits must match too.
   2. The same camera model on both, and present on both.
   3. The same pixel dimensions in either orientation, or the same stem once collision suffixes are removed.
   4. Exactly one candidate on the other side, so the match is one-to-one. Bursts and ambiguity drop out.

   This rule found 826 duplicates, 816 of them byte-size identical. Split the matches into buckets:
   - **identical:** same size.
   - **apple-edited:** the Apple side has adjustments, so Amazon held the edited render.
   - **not obvious:** leave these alone.
3. **Apple's fingerprint.** Run `osxphotos import <dir> --walk --skip-dups --dry-run --verbose`. It is read-only and works on a temp copy of the Photos database. Parse the log for "appears to be a duplicate".
   - It misses re-rendered and edited copies.
   - It also misses files whose extension makes Photos treat them as RAW.
   - Re-dating or converting a copy changes its fingerprint. Run it on the untouched originals too.
4. **Perceptual hashes:** 64-bit pHash plus dHash, with thresholds below. Use [scripts/phash_pairs.py](scripts/phash_pairs.py).
5. **Same name and size or dimensions.** This is weak, and only worth reporting alongside other evidence.

A capture second shared by 3 or more files is a **crowd** (a burst, or batch-stamped scans). It is not evidence of duplication.

## Perceptual hash thresholds (Hamming distance, 64-bit)

| Grade | Rule | Action |
|---|---|---|
| certain | MD5 equal, or both dated within 1 s and pHash ≤ 8 | Auto-suggest a duplicate |
| strong | pHash ≤ 4 and dHash ≤ 6 and same aspect ratio (±0.02, either way round) | Suggest a duplicate and show it to the user |
| review | pHash ≤ 10 and dHash ≤ 12, or dated more than 120 s apart | Show it. Usually a different frame of the same scene |

**Practical points:**
- Hash thumbnails of at most 512 px, not originals:
  - Images: `sips -s format jpeg -Z 512`.
  - Videos: `qlmanage -t -s 512`. `.mkv` files can hang it, so use a 45 s timeout and re-run only the misses.
- Apply EXIF orientation before hashing (`ImageOps.exif_transpose`).
- A copy that was physically rotated won't match its original, because the hashes don't survive rotation. If rotated copies are likely (scans, for example), also hash the 90°, 180° and 270° versions.
- For Apple-side images, hash Photos' own preview JPEGs, which osxphotos lists as `path_derivatives`. Copy them out with `cp -n` from a shell that has Full Disk Access (see `apple-photos-automation`).
- Compare all pairs fast with numpy: XOR blocks of uint64 hashes, then `np.bitwise_count`, which needs numpy 2. Run it with `uv run --with pillow --with imagehash --with numpy python …`.

**The final "anything we missed?" sweep** ran three kinds of evidence against every Apple item:
- **Closest visual:** the nearest Apple item by hash distance.
  - Strong: pHash ≤ 6 and dHash ≤ 10.
  - Possible: either hash ≤ 12.
- **Same moment allowing a time-zone shift:** the same second after shifting by any whole hour from 0 to ±12, plus the same aspect ratio.
- **Same name:** the same stem (at least 4 characters) plus the same size or dimensions.

It flagged 207 visual look-alikes (all different pictures), 1 real duplicate by moment, and 8 name hits (all reused iPhone numbers). That's normal. Expect to look at the weak tiers and reject most of them.

## Picking the keeper

1. **Apple Photos always wins** over an imported copy. The user's Apple originals, edits, People and albums are worth more.
2. Within one source, prefer in this order:
   1. An original format over a converted copy or an Apple-made preview. `UUID_1_105_c.jpeg` and `*_4_5005_c.jpeg` names are previews, never keepers.
   2. Real camera make and model.
   3. More pixels.
   4. A larger file.
   5. A file from a user folder rather than a machine-backup folder.
   6. A clean name without a ` (2)` or upload-stamp suffix.
   7. A descriptive name.
3. **RAW + JPEG is a pair, not a duplicate.** Keep both.
4. **Group duplicates with union-find** over the certain and strong edges only. Review-grade edges are usually different shots.
5. Before filing a loser away, **move its better metadata onto the keeper**: date, People, album, favourite.

## Low-value items (same review loop)

Score each image, flag the high scorers for review, and let the user mark keepers. Archive the rest, never delete. On-device Vision (`VNClassifyImageRequest`, `VNRecognizeTextRequest`, `VNDetectFaceRectanglesRequest`, built as a small Swift tool) gives you labels, text and faces.

| Points | Signal |
|---|---|
| +3 | Max side ≤ 256 px |
| +3 | Software or app asset |
| +2 | Max side < 500 with no camera data |
| +2 | Exact phone-screen dimensions with no camera data |
| +2 | Labels receipt, document or screenshot (≥ 0.3 confidence) |
| +2 | 8 or more lines of text and no faces |
| +2 | Near-blank |
| +1 | Small PNG, GIF or BMP |
| +1 | Under 15 KB with no camera data |
| +1 | Text, chart or handwriting labels |

**Keep** anything with faces or people-type labels.

Don't apply the size or screen rules to videos. They flagged videos as screenshots.

"Same session as a flagged photo" rules need to be tight: same folder, same name prefix, file numbers within 8, and within 3 hours. A loose version produced about 500 candidates; the tight one produced 16.

## Showing the user

- **Contact sheets** (made with Pillow): duplicate on the left, keeper on the right, about 260 px cells, with size, date and name under each. Show a sample from each bucket *before* moving anything.
- **For decisions at volume,** run a small local review server: stdlib `http.server` on 127.0.0.1 only.
  - Give it queues and paging (about 40 items a page), with keyboard-friendly buttons, a lightbox and "accept page".
  - POST each decision to SQLite as `review_decisions(queue, file_id, decision, suggested, decided_at)`. The server moves nothing.
  - Serve HTML with `Cache-Control: no-store`, or reloads show stale pages.
  - Stop the server before heavy database work. A held connection produced "database disk image is malformed" during a verification run.
- **Protect privacy:** blank out any private or explicit thumbnail before sharing a sheet. Never identify people by face yourself. Use the provider's People tags only as suggestions.

## Related skills

- `amazon-photos-export`: getting the source.
- `photo-date-repair`: dates feed the same-moment checks.
- `apple-photos-automation`: osxphotos and permissions.
- `photo-library-migration`: the full pipeline.
