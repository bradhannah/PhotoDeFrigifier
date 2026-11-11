---
name: photo-library-migration
description: Plan and run a safe one-time move of a photo library from one service into Apple Photos (Amazon Photos, Google Photos/Takeout, Dropbox, old drives or iPhoto exports) without losing anything, without duplicates, and without ever deleting from the destination. Covers measuring both sides, a verified download, an SQLite index, duplicate filing, a date plan, staged copies with sidecars, dry runs with a positive control, a pilot, batch imports with an undo ledger, checking every item, and working with the user along the way. Use this whenever someone wants to move, consolidate, merge or leave a photo service, cancel a photo subscription, or import a big pile of old photos into Apple Photos, even if they describe it casually ("get my Amazon pictures into my iPhone photos").
---

# Photo library migration playbook

This came from a real move: about 7,900 Amazon Photos files went into an Apple Photos library of 4,795 items. The result was 5,030 imported, 5,029 matching the plan exactly, no duplicates, and nothing in Apple Photos deleted. The detailed techniques are in the related skills; this file is the order of work and the rules that kept it safe.

## Standing rules (agree these with the user first and restate them after any context reset)

1. **Nothing is ever deleted from the destination library.** The import only adds items, albums and keywords.
2. **The destination's copy wins** any duplicate. It holds the user's edits, People, albums and iCloud history.
3. **Set things aside instead of deleting.** Duplicates, junk and excluded items are *moved* into folders, with logs and undo. Eventual deletion happens only on the user's explicit say-so.
4. **Originals are never modified.** All fixes happen on staged copies.
5. **Ask before each irreversible or outward-facing step:**
   - downloading
   - deleting a verified local copy
   - moving files
   - starting each import batch

   An approval covers that step only.
6. **Don't hand out undo or destructive commands "just in case".** A user ran one that was listed as optional and then had to ask why. Give them only when asked, clearly labelled.
7. **Honour exclusion lists.** People or content the user doesn't want carried over go to `excluded/`, and their names never become keywords.
8. **Never identify people by their faces yourself.** Use the source service's People tags as suggestions only.
9. **Watch for sensitive files.** Cloud drives hold recovery codes and password-manager kits. Point them out, never open them, and recommend an encrypted home for them.

## Phases

0. **Measure both sides before planning.** The user's picture of their library is usually wrong. In this case:
   - The user thought Apple stopped about 1.5 years ago. It actually went back to 2007.
   - Their "complete" Amazon download held 4,891 of 7,915 media files.

   Count by year and by type on both sides.
1. **Take a complete, verified copy of the source.** Inventory it with checksums, download it, then prove every MD5 is present on disk. Check folders, trash and family vaults, not just the photo view. See `amazon-photos-export`.
2. **Snapshot the destination.** Save `osxphotos query --json` output. It is the before picture for the final audit. See `apple-photos-automation`.
3. **Index everything into one SQLite database** (see the schema below). Snapshot the database (`sqlite3 .backup`) before every stage that changes it.
4. **Match and file duplicates.** Work through the evidence ladder and keeper rules in `photo-duplicate-finding`. Show the user a contact sheet of samples before any move.
5. **Set aside low-value items** (screenshots, thumbnails, app assets) for the user to review and mark keepers. Set aside excluded content too.
6. **Make a date plan.** Audit every date, plan a fix for each one, and agree the placeholder conventions with the user. See `photo-date-repair`.
7. **Stage the files.** Put copies into numbered batch folders, each with a sidecar holding its date, keywords (including People names), favourite and GPS. Also:
   - Fix wrong extensions.
   - Convert BMP to PNG with a pixel-identity check.
   - Make file stems unique within each batch.
   - Write a `_manifest.csv` with the original path, MD5, plan, expected Photos date, keywords and albums.
   - Re-hash the originals to prove nothing changed.
8. **Dry-run with a positive control.** Run `osxphotos import … --skip-dups --dry-run`, including on the untouched originals of re-dated copies. A planted set of known duplicates must be caught; that proves the check works.
9. **Run a pilot** of about 14 varied files. Give the user a **manual checklist** for the pilot (date, keywords, map pin, favourite, album, "stored in library") so they can confirm it in Photos themselves.
10. **Import in batches** by era (Undated, then year ranges), at most about 30 minutes each. For every batch:
    - Build the undo ledger from the resume database.
    - Finish albums.
    - Correct dates for the batch's own items.
    - Check every item.

    Recipe: `apple-photos-automation/references/osxphotos-import.md`.
11. **Audit the whole library** against the snapshot. Expect `before + imported + whatever the user added meanwhile`; explain every extra item.
12. **Hand over:**
    - Let iCloud finish uploading.
    - Check Photos ▸ Utilities ▸ Duplicates for any imported item. Anything there was missed by every check.
    - Leave a plan document with the results, procedures and undo steps.
    - The user cancels the old service themselves.

Leave out items you shouldn't guess about. Here that was recent phone photos missing from Apple, which the user had probably deleted on purpose. Put them in a "check first" batch that isn't imported unless the user says so.

## SQLite index (what worked)

- `files`: one row per file per source. Columns:
  - identity: `source`, `source_key` (path or Photos UUID), `filename`, `base_name` (lowercase, suffix removed), `ext`, `size_bytes`, `sha256`, `md5`
  - attributes: `width`, `height`, `make`, `model`, `duration_s`
  - every candidate date: `exif_dto`, `exif_create`, `qt_create`, `filename_date`, `file_mtime`, `apple_date`
  - the chosen date: `taken_at`, `taken_source`, `date_flags`
  - `category`
  - `exif_json` (the raw exiftool record)
  - `UNIQUE(source, source_key)`
- `cloud_files`: the provider inventory (cloud ID, md5, size, content date, folder path).
- `matches(a_id, b_id, method, score)`, and `decisions(file_id, decision, reason, decided_by='rule:<name>'|'user')`.
- Scan tables: `visual_hash`, `scan_visual_pairs`, `scan_apple_match`, `scan_amazon_clusters`, `scan_low_value`, `final_apple_check`.
- Date tables: `date_audit`, `date_plan(file_id, plan keep|shift|assign|placeholder, new_date, keyword, reason)`, `date_overrides`.
- Review: `review_decisions(queue, file_id, decision, suggested, decided_at)`.
- Archive tables (`files_dup_of_apple`, `files_excluded`, `files_low_value` …) are made with `CREATE TABLE … AS SELECT * FROM files WHERE 0`. Moving rows into them keeps the working set clean and reversible.

## Working with the user

- **Show, don't list.** Contact sheets go to the user before every bulk move. For decisions at volume, use a local review page (127.0.0.1 only) whose choices are saved to SQLite, so reloads lose nothing.
- **Explain progress in their terms:** items, years, albums. Hide internal IDs.
- **Long runs:**
  - Run them in the user's Terminal panel when they need Photos access.
  - Wait with `until grep -q 'DONE\|INTERRUPTED' log; do sleep 30; done`-style loops.
  - Report `(n/N)` progress.
  - If the user interrupts and then says "keep going", continue only the work already approved.
- **When a batch hiccups** (Photos stalls, a few files error out), re-run the same command. `--resume` and fingerprint skipping make that safe. Then check the counts.
- **Keep a living plan document** (`IMPORT_PLAN.md`) with status, results, procedure and the undo matrix:
  - stop and re-run
  - undo everything, one batch or chosen files, via an UNDO album
  - Recently Deleted keeps items 30 days
  - fix dates with Adjust Date and Time

  Keep timestamped backups of the plan before major revisions.

## Related skills

`amazon-photos-export`, `photo-duplicate-finding`, `photo-date-repair`, `apple-photos-automation`, `photo-review-store`.
