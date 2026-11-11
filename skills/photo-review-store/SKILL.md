---
name: photo-review-store
description: Read and act on the tags and history that the PhotoDeFrigifier quick-fix app saves for Apple Photos items. This covers verdicts (Good Enough, Look at Later, Everything is in Order!, Archived), markers (To Delete, Blurry, To Records), notes, approximate dates and pass progress, kept in ~/Library/Application Support/PhotoDeFrigifier/review-store.json plus an actions.jsonl log. Use this whenever the user asks what they've reviewed, wants a report on their photo clean-up, wants to act on photos they tagged (add keywords, export, list, re-queue), or plans the next clean-up pass, even if they just say "what did I mark last week?"
---

# PhotoDeFrigifier review store

The PhotoDeFrigifier app (repo `~/GitHub/PhotoDeFrigifier`) shows Apple Photos items one at a time. Each tap is recorded in a JSON store, and that store is what you use to plan the next round of clean-up.

## Files

All of these live in `~/Library/Application Support/PhotoDeFrigifier/`.

| File | What it is |
|---|---|
| `review-store.json` | The current state: one record per photo, plus pass progress per scope. The app keeps it in memory and rewrites the whole file after each action. |
| `review-store.backup.json` | The file as it was when the current app session started. |
| `actions.jsonl` | Append-only history. Each line is `{at, asset, filename, action, before, after, scope}`. Actions: `verdict`, `flag`, `unflag`, `archive`, `hide`, `date`, `rotate`, `favorite`, `note`, `skip`, `delete`, `export`, `album-add`, `album-remove`, `album-create`, `undo`. Album changes live only here and in Photos, not in the store. |
| `self-check.json` | Read-only diagnostics written by `open PhotoDeFrigifier.app --args --self-check`. |

**Quit the app before you write to `review-store.json`.** The app holds the store in memory and overwrites the file on its next action, so edits made while it's running are lost. Reading while it runs is fine.

## review-store.json

```json
{
  "format": "photodefrigifier-review-store",
  "version": 1,
  "updatedAt": "2026-11-08T14:30:00Z",
  "assets": {
    "6F1C…-…/L0/001": {
      "filename": "IMG_0320.jpg",
      "verdict": "lookLater",
      "verdictAt": "2026-11-08T14:29:51Z",
      "flags": ["blurry", "records"],
      "reviewCount": 2,
      "lastReviewedAt": "2026-11-08T14:29:51Z",
      "dateApproximate": true,
      "note": "Grandpa's workshop?",
      "exportedTo": "/Users/…/My Drive/Personal Records/IMG_0320.jpg",
      "deletedAt": null,
      "hiddenAt": null
    }
  },
  "passes": {
    "library": { "number": 2, "seed": 81273, "startedAt": "…", "skipped": ["…/L0/001"] },
    "queue:undated": { "…": "…" },
    "album:<collection local id>": { "…": "…" }
  }
}
```

- **Keys** are PhotoKit local identifiers, `<UUID>/L0/001`. The `<UUID>` part is the osxphotos `uuid`, so strip `/L0/001` to use osxphotos or photoscript on it.
- **verdict** is the closing call on a photo for a pass:

  | Value | Button | Meaning |
  |---|---|---|
  | `goodEnough` | Good Enough | Fine as it is, but it could still be better. |
  | `lookLater` | Look at Later | Needs another look. |
  | `inOrder` | Everything is in Order! | Done. Left out of later passes by default. |
  | `archived` | Archive (A) | Keep, but out of sight: the photo has the Photos keyword **Archived**. It is hidden later in a batch (one macOS confirmation), which sets `hiddenAt`; until then it's still visible. Left out of later passes. |

- **flags** are markers for work to do outside the review:
  - `delete`: the user wants it gone. Deleting happens in the app's delete review, through macOS's own confirmation.
  - `blurry`: a quality note. It does **not** imply deletion.
  - `records`: save the original to the user's records folder (Google Drive, Personal Records). After a successful save, the app sets `exportedTo` and adds `delete`.
- **hiddenAt** is when the app hid the photo in Photos (the batch hide for archived photos). `archived` without `hiddenAt` means tagged but still visible.
- **dateApproximate** is set when the date was entered as a year or month only. It follows the date conventions in `photo-date-repair`: year only gives 1 July at noon, and a known month gives the 15th.
- **passes**: one per scope (`library`, `queue:<name>`, `album:<id>`).
  - A photo counts as done for a pass when `lastReviewedAt >= startedAt`.
  - `seed` fixes the shuffled order.
  - `skipped` holds photos sent to the back of the queue.
- **Missing fields** mean "not set". Older or partial records still decode.

## Albums the app keeps in Photos

When "Mirror markers to albums" is on (the default), Photos has a folder **Quick Fix** containing the albums **To Delete**, **Blurry**, **To Records** and **Look at Later**. These mirror the store. They sync to the user's other devices through iCloud and are handy in Photos itself, but the JSON store is the source of truth.

## Common jobs

All the scripts below read the store. Writing to Photos needs the tools and permissions in `apple-photos-automation`; run those in the user's Terminal panel.

```python
import json, os, collections
store = json.load(open(os.path.expanduser("~/Library/Application Support/PhotoDeFrigifier/review-store.json")))
recs = store["assets"]
uuid = lambda key: key.split("/")[0]                       # osxphotos / photoscript UUID

print(collections.Counter(r.get("verdict") for r in recs.values()))
print(collections.Counter(f for r in recs.values() for f in r.get("flags", [])))
look_later = [r.get("filename") for r in recs.values() if r.get("verdict") == "lookLater"]
approx = [uuid(k) for k, r in recs.items() if r.get("dateApproximate")]
```

- **Progress report:** reviewed vs total, per verdict, per flag, and this week's activity from `actions.jsonl`. Ask the user before publishing it anywhere.
- **Carry "Date approximate" into Photos** (PhotoKit can't write keywords). For the `approx` UUIDs, run a photoscript script in the Terminal panel that adds the `Date approximate` keyword, and remove `Undated` if it's there. Write a before/after CSV.
- **Blurry review:** list the `blurry` items that aren't also marked `delete`, and show them to the user as a contact sheet before suggesting anything.
- **Re-queue:** to review a set again, quit the app and remove those photos' `lastReviewedAt` (or start a new pass from the app). Never delete records; the history matters.
- **Deleting:** don't delete photos from scripts. The app's delete review uses Apple's confirmation, and the user decides there.

## Related skills

- `apple-photos-automation`: identifiers, osxphotos, photoscript.
- `photo-date-repair`: date conventions.
- `photo-duplicate-finding`: deeper clean-up.
