---
name: apple-photos-automation
description: Read, import into and change the Apple Photos library on a Mac from scripts or apps, using osxphotos, photoscript/AppleScript or PhotoKit (Swift). Covers which tool can do what (keywords, People, dates, albums, favourites, rotation, deletion), macOS permissions (Full Disk Access, Automation, and why Claude's own shell can't read the library), the osxphotos import recipe with sidecars, resume and crash recovery, Photos quirks (-609 errors, hangs, mislabelled RAW files, referenced files), and checking results afterwards. Use this whenever a task touches Apple Photos or a .photoslibrary: querying it, exporting, importing, bulk-editing dates, keywords or albums, building a Swift photo app, or debugging "Operation not permitted" on the library.
---

# Automating Apple Photos on macOS

## Choose the tool by the job

| Job | Tool | Notes |
|---|---|---|
| Read everything (dates, keywords, People, albums, paths, fingerprints, preview files) | **osxphotos** (Python) | Read-only; works on a temp copy of the Photos database. Needs Full Disk Access. |
| Import files with metadata | **`osxphotos import`** | Drives Photos via AppleScript, one file at a time. Recipe in [references/osxphotos-import.md](references/osxphotos-import.md). |
| Set dates, albums, keywords or titles on existing items | **photoscript** inside `osxphotos run` | AppleScript underneath, so Photos must be running. |
| An app (SwiftUI) that shows photos and makes edits | **PhotoKit** | Can change date, location, favourite, hidden and albums, rotate (as an edit you can revert) and delete (behind Apple's own prompt). **Cannot read or write keywords, captions or People names.** Notes in [references/photokit.md](references/photokit.md). |
| Put People names on photos | **Not possible from outside** | Nothing can fill Apple's People album. Write the names as **keywords** instead, so they stay searchable. |

**Install:** `brew install exiftool` and `uv tool install osxphotos` (0.78.0 was used). osxphotos' own Python lives at `~/.local/share/uv/tools/osxphotos/bin/python`. Run scripts that import `osxphotos` or `photoscript` with `osxphotos run script.py args…`.

## Permissions

- **Reading the library** (`~/Pictures/Photos Library.photoslibrary`) needs **Full Disk Access** for the process doing the reading.
- **The first AppleScript call** brings up "Terminal wants to control Photos". The user must click Allow.
- **Claude's own Bash tool may never get Full Disk Access**, even when Claude.app has it. In the Claude desktop app, commands run through a helper that doesn't inherit the grant, so `ls` on the library says "Operation not permitted".
  - **Workaround:** run library-touching commands in the user's **Terminal panel** (`run_in_terminal`, read back with `read_terminal`). That runs in the user's own terminal, which does have access.
  - Send the output to files, then read the files from Bash.
  - Keep the number of open terminal tabs small, and close finished ones.
- **A PhotoKit app** needs `NSPhotoLibraryUsageDescription` in its Info.plist, and it must run as an `.app` bundle so macOS can show the access prompt.
  - With ad-hoc signing (`codesign -s -`), every rebuild can make macOS ask again.
  - Signing with an Apple Development certificate keeps the grant between builds.
- To open the Full Disk Access pane: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"`.

## Reading with osxphotos

```bash
osxphotos query --json > apple_query.json                 # whole library; ~4,800 items took seconds
```

**Useful `PhotoInfo` fields:**
- identity and file: `uuid`, `original_filename`, `fingerprint`, `original_filesize`, `width`, `height`
- dates: `date` (aware datetime), `date_added`, `date_trashed`
- metadata: `keywords`, `persons`, `albums`, `album_info`, `location`, `favorite`
- state flags: `hidden`, `intrash`, `isreference`, `ismissing`, `hasadjustments`, `iscloudasset`, `shared`, `syndicated`
- kind: `ismovie`, `israw`, `live_photo`, `screenshot`, `burst`
- files: `path`, `path_derivatives` (Photos' own preview JPEGs, handy for visual matching), `exif_info`

```python
import osxphotos
db = osxphotos.PhotosDB()
photos = db.photos(uuid=[...], intrash=False)      # intrash=True lists Recently Deleted
```

**Snapshot before you change anything.** Save `osxphotos query --json` output first. Afterwards, compare the live library with it:
- new items not made by you
- snapshot items now missing
- snapshot items now in Recently Deleted

That one check proved the original 4,795 items were all still there after a 5,030-item import. It also explained 3 unexpected extras: iPhone photos the user took that afternoon.

## Changing existing items (photoscript)

```python
from photoscript import Photo
Photo(uuid).date = datetime(2008, 8, 2, 19, 16, 52)        # wall-clock local time
from osxphotos.photosalbum import PhotosAlbumPhotoScriptByPath
PhotosAlbumPhotoScriptByPath(["From Amazon", "Events", "Wedding"]).update([Photo(u) for u in uuids])
```

- Change only items you can prove you created, using a ledger of UUIDs.
- Write a before/after CSV for every change. That CSV is your undo.

## Photos quirks that cost hours

- **Keep Photos open during any AppleScript-driven job.** If it quits, the next call fails with `Connection is invalid (-609)` and osxphotos crashes. After a relaunch Photos can also hang with no window, blocking AppleEvents. Then:
  1. Stop your scripts.
  2. Have the user force-quit and reopen Photos.
  3. Resume.
- **Photos goes by the file extension.** Old iPhoto exports included `.nef` and `.png` files that were really JPEGs; check for the `FF D8 FF` magic bytes. Photos labels such a file RAW. Give it the right extension before import.
- **Same-stem files in one folder get paired** as RAW+JPEG or Live Photo. Make stems unique within each import folder.
- **"Copy items to the Photos library"** must be on (Photos ▸ Settings ▸ General). A referenced file never uploads to iCloud. Check `isreference` after import; scripts can't read the setting itself.
- **Photos sometimes rejects valid files** with "Error importing" (5 NEFs did once). A plain re-run usually works.
- **`osxphotos import --stop-on-error N`:** when the limit is hit, osxphotos restarts Photos and carries on. The errored files are left out. Re-run the same command later; `--resume` picks up only those.
- **Video dates:** see `photo-date-repair`. Photos reads QuickTime times as UTC unless an offset is stored, and AVI dates not at all.
- **Deleting:** Recently Deleted keeps items for 30 days. The safest pattern for a bulk undo is to gather the UUIDs into an album ("UNDO – review then delete") and let the user delete them by hand. Never delete for the user.

## Checking an import

After every batch, read Photos back and compare it with the plan:
- the item exists and isn't in the trash
- it isn't a referenced file
- the date is within 60 s of the planned date
- every planned keyword is there
- location and favourite match
- it's in the expected albums

Also count items you staged but that never got a UUID; those weren't imported. Print `verified OK N, problems M`, and treat "problems 0" as believable only if the import itself finished (`set -o pipefail`).

## Related skills

- `photo-date-repair`: date rules.
- `photo-duplicate-finding`: Apple's fingerprint and visual checks.
- `photo-library-migration`: the whole pipeline.
- `photo-review-store`: tags from the PhotoDeFrigifier review app.
