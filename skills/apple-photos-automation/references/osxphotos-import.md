# osxphotos import: a recipe that survived 5,030 files

## Command

```bash
osxphotos import "$SRC" --walk --sidecar --favorite-rating 5 --skip-dups \
  --album "From Amazon/All from Amazon" --album "From Amazon/Import batches/$BATCH" --split-folder "/" \
  --report "$OUT/import-$SLUG.json" --append --resume --stop-on-error 5 --verbose --timestamp \
  2>&1 | tee -a "$LOG"
```

| Option | Why |
|---|---|
| `--walk` | Recurse into the staging folder. |
| `--sidecar` | Read `<file>.<ext>.json` next to each file (format below). |
| `--favorite-rating 5` | `XMP:Rating` 5 becomes a Favourite. |
| `--skip-dups` | Skip anything whose Apple fingerprint is already in the library. It reads a temp copy of the database. |
| `--album A/B` + `--split-folder "/"` | Creates nested folder/album paths. |
| `--report … --append` | A JSON report, **written only at the very end**. A crash loses it (see below). |
| `--resume` | Skips files already recorded in the resume database, so re-running is safe. |
| `--stop-on-error 5` | Bounds the damage. When the limit is hit, osxphotos restarts Photos and the errored files are left for a re-run. |
| `--merge-keywords` | Add this if the items already have keywords. Otherwise sidecar keywords **replace** them. |

**Dry run:** add `--dry-run --no-progress`. It's read-only and still runs the duplicate check and sidecar parsing. Look in the log for "Unknown sidecar type" and "appears to be a duplicate". Throughput for real imports is about 1 to 2 s per file; a batch of 992 files took about 30 min.

## Sidecar format (exiftool-style JSON)

osxphotos only treats a `.json` sidecar as an exiftool sidecar if it is a **list with one object** that contains `ExifTool:ExifToolVersion`. Without that key you get "Unknown sidecar type".

```json
[{
  "SourceFile": "IMG_0001.jpg",
  "ExifTool:ExifToolVersion": 13.55,
  "XMP:Subject": ["From Amazon", "Date approximate", "A Person Name"],
  "EXIF:DateTimeOriginal": "2005:12:25 12:00:00",
  "XMP:Rating": 5,
  "XMP:GPSLatitude": 20.2114,
  "XMP:GPSLongitude": -87.4654,
  "XMP:Title": "",
  "XMP:Description": ""
}]
```

- **Date:** naive local wall-clock time.
- **GPS:** signed decimal degrees.
- **Captions:** an empty `XMP:Description` clears junk camera captions such as "OLYMPUS DIGITAL CAMERA".
- **Check before importing:** read every sidecar with `osxphotos.metadata_reader.metadata_from_sidecar(path, None)` (run under osxphotos' Python with `-I`) and compare against your plan.

## Crash-proof ledger: the resume database

`~/.local/share/osxphotos/osxphotos_import.db` is SQLite, with a table `data(key TEXT = file path, value = JSON)`. It is written **after every file**.

The value fields are: `albums`, `description`, `error`, `filename`, `filepath`, `import_datetime`, `imported`, `keywords`, `location`, `title`, `uuid`, `datetime`, `skipped`, `duplicate_of`.

Build your undo ledger (uuid, staged path, batch, time) from this database, not from `--report`.

**Items that reached Photos just before a crash:** the verbose log has `-- Importing <path> (n/N)` followed by `-- Imported <name> with UUID <uuid>`. A UUID in the log with no resume record means the item landed in Photos, but the crash came before osxphotos recorded it. To recover:
1. Back up the database.
2. Insert a record for it in the same JSON shape, so a re-run won't import it a second time.
3. Finish its albums and dates afterwards.

## Batch wrapper pattern

1. **Guard:** exit if every staged file in the batch already has a UUID in the ledger.
2. **Run the import** with `set +e`, piped through `tee`. Capture the exit code with `set -o pipefail`, otherwise `tee` hides the failure.
3. **Always run the follow-ups, even after a failure:**
   - ledger from the resume database
   - finish albums for incomplete items
   - fix dates
   - verify
4. **Exit code not zero:** print "INTERRUPTED … make sure Photos is open, then run the same command again" and exit 1. Otherwise print "DONE".

Splitting batches by era (an Undated batch, then ranges of years) keeps each run under 30 minutes and makes problems easy to locate. Run a **pilot of about 14 varied files** first, covering:
- HEIC, AVI, MOV from an old camera, phone MP4
- NEF, PNG, GIF
- a scan with no date
- a favourite, one with GPS, one with People names

The pilot caught three real bugs: video clocks, AVI dates and mislabelled extensions.

## Post-import albums

`osxphotos run post_import_albums.py records.json` reads each record's planned albums and adds them with `PhotosAlbumPhotoScriptByPath`. For osxphotos' `--post-function` hook, the signature is `(photo, filepath, verbose, report_record)`.
