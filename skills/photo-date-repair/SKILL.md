---
name: photo-date-repair
description: Audit, infer and fix the capture dates of photos and videos, especially before importing into Apple Photos. Covers which date fields to trust, camera clocks that were wrong or reset, filename and folder hints, scans with no date, the 1900 placeholder and "Date approximate" conventions, how Apple Photos reads video times (UTC vs local), AVI and PNG files Photos can't date, daylight-saving gaps, and checking dates after import. Use this whenever photos show the wrong date or year, sort in the wrong place, sit at 1900/1970/2000, need redating, or are about to be imported or migrated, even if the user only says "these are out of order".
---

# Photo date repair

Wrong dates are the main thing that makes a migrated library feel broken. In a migration of about 5,500 files, the audit found:

| Status | Files |
|---|---|
| Good | 4,325 |
| Fixable | 138 |
| No usable date | 1,078 |

The final plan left 4,236 alone, marked 561 as approximate, and put 224 at a placeholder.

## 1. Record every candidate date

For each file, store every candidate date side by side (in SQLite, for example), plus the date you chose and where it came from.

Collect the candidates with `exiftool -json -r`:
- `DateTimeOriginal` (with `SubSecDateTimeOriginal` and `OffsetTimeOriginal`)
- `CreateDate` (EXIF and XMP)
- QuickTime `CreationDate` (carries a time zone offset) and `CreateDate` / `MediaCreateDate`
- a date parsed from the filename
- the file's modification and creation times

Normalise as you go. `YYYY:MM:DD` becomes `YYYY-MM-DD`. Reject any value starting `0000`. Repair malformed scanner values such as `2009:01:11 17:47: 9`, which crashed a script.

Choose in this order:
1. `DateTimeOriginal`
2. `CreateDate`, for photos only
3. QuickTime date
4. filename date
5. none

Store the chosen date as `taken_at` and the source as `taken_source` (exif_dto | exif_create | qt_create | filename | inferred_neighbor | none).

**Never trust file modification times from a download or cloud export.** Amazon's downloads stamped 1,627 files with one time. Amazon's `contentDate` is local time wrongly labelled `Z`. Don't convert it from UTC.

## 2. Mark suspect dates

Mark a date as suspect, with a reason, when any of these is true:

- **Impossible year:** before 1990 or after this year, for digital files.
- **A camera's factory default:** midnight on 1 January in 1970, 1980, 1990 or 2000 to 2006.
- **Before the camera existed:** keep a small model-to-release-year table.
- **Far from the camera's usual years.** For each camera model with at least 20 dated photos, take the median year. Mark files more than 4 years away.
- **A year hint that disagrees.** A year in the filename or a meaningful parent folder differs by more than 1.
  - Count a year only when it is its own word. `IMG_2007.JPG` and `100_2008.JPG` are file numbers.
  - Skip generic folder names.
- **Batch-stamped:** 3 or more different files with no camera make share the exact same second. That is typical of scanners and old iPhoto imports.

### Inferring from neighbours

If the camera numbers its files, a suspect photo can take the date of the nearest correctly dated frame from the same camera:
- the trailing digits of the filename are within 200
- use only the date part
- set `taken_source='inferred_neighbor'`

### Camera clock reset

A Kodak Z650 reset its clock to 2025-01-01 12:00 and then ran for months, until its owner set it. The fix:
1. Find an anchor photo whose real date you know from its content. Here, Christmas trees appeared at camera time "2025-07-01", which really meant 2005-12-25.
2. Apply one constant shift: `datetime(2025,7,1) - datetime(2005,12,25)`.
3. Tag every shifted photo `Date approximate`.

When the user remembers a different year than the EXIF shows, ask them. Don't silently overwrite. In this library the camera was right.

## 3. Conventions for dates that aren't known

The user agreed these, and they work well in Apple Photos:

| Situation | Date to set | Keyword |
|---|---|---|
| Nothing known | `1900-01-01 12:00:00` (tested in Photos; it sorts first) | `Undated` |
| Year only | `YYYY-07-01 12:00:00` | `Date approximate` |
| Month known | the 15th, `12:00` | `Date approximate` |
| Known day (an event, a batch of scans) | that day at `12:00` | `Date approximate` |
| Filename `YYYYMMDD_HHMMSS` (when the file was saved) | that time | `Date approximate` |
| Filename "Photo on YYYY-MM-DD at H.MM PM" (Photo Booth) | that exact time | none |

Noon avoids time-zone rollovers to the previous day. Queues such as "all Undated" are easy to find later by keyword, or by `year < 1902`.

A quick year picker (1999 to now, plus "Unsure" and "Just delete it") in a local review page let the user date hundreds of scans quickly.

## 4. Apple Photos and video times

- **QuickTime dates count as UTC** unless the file stores a time zone offset.
  - iPhones store `CreationDate` with an offset, so they come out right.
  - Phone MP4s that store true UTC also come out right. Photos shows them in local time, so the expected display time is UTC converted to local.
  - **Older cameras (Kodak, for example) wrote their local clock into the QuickTime fields.** Photos then shows those clips 4 to 5 hours early. The proof was a clip landing 19 s after the previous photo from the same camera, once corrected.
- **Classify each video's clock** before import:
  - `offset`: the QuickTime string is longer than 19 characters.
  - `utc`: the filename date is 3.5 to 5.5 hours ahead of the QuickTime date.
  - `local`: modification time minus QuickTime date minus duration is between −0.3 and +1.3 hours, or the camera's reset value appears (`2006-01-01…`).
  - Otherwise, treat it as `utc`.
  - Set an explicit date for `local` clips.
- **AVI (RIFF) dates can't be read by Photos.** It uses the file date. Set the date explicitly.
- **PNG EXIF may be ignored.** Set the date explicitly.
- **BMP can't hold a date.** Convert it to PNG losslessly, check the pixels are identical, then set the date.

## 5. Writing dates without touching originals

- Work on **staged copies**. Write the date into each copy only where Photos won't read the file's own date. Use an exiftool argfile with `-overwrite_original … -execute` blocks setting `-EXIF:DateTimeOriginal` and `-EXIF:CreateDate`. Then check that the decoded pixels are unchanged and read the date back.
- Everything else travels in the import sidecar. See `apple-photos-automation` for the osxphotos sidecar format.
- Set each copy's modification time to the planned date as a fallback. Skip dates before 1904, which the HFS+ format can't store.
- Remove junk `0,0` GPS (`-GPS:all=`), or the photo pins to the ocean off Africa.

## 6. Daylight-saving gap

A local time inside the skipped spring-forward hour doesn't exist. For example, 2006-04-02 02:16 in America/Toronto. Photos shows it an hour earlier (01:16). Report it and leave it; it's harmless.

## 7. Check every date after import

- Check **every** imported item's date in Photos against the plan, not only the ones you set. The pilot showed that dates Photos reads from the files themselves can be wrong too.
- Allow 60 s of tolerance.
- Compare `PhotoInfo.date.replace(tzinfo=None)` (osxphotos) with the planned local wall-clock time.
- Correct differences only on items your import added: `photoscript.Photo(uuid).date = datetime(...)`. Write a before/after CSV.
- Inside the Photos app, *Image → Adjust Date and Time* does the same thing by hand.

## Related skills

- `apple-photos-automation`: osxphotos, photoscript, PhotoKit `creationDate`.
- `photo-duplicate-finding`: same-moment matching depends on good dates.
- `photo-library-migration`: the whole migration.
