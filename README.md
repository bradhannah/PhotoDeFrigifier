# PhotoDeFrigifier

A Mac app for quick, repeatable clean-up of an Apple Photos library. It shows one photo at a time with one-key fixes, so a session can be 5 photos or 500. Everything it learns goes into a JSON store, so later passes (and scripts, and Claude) can build on it.

> Earlier versions of this repo were a multi-provider reconciliation catalog. That code was retired in favour of this app; it's still in the git history before the `photo-quick-fix` branch.

## What it does

- **Sidebar**
  - **All Photos.**
  - **Needs a Look:** not reviewed yet, Undated (1900), screenshots, short videos, low resolution, no location.
  - **Marked:** Look at Later, To Delete, Blurry, To Records.
  - **Every album and folder** in your library. Pick one to work through just that album.
- **Fix:**
  - **Rotate** (E / R) as a normal Photos edit, so "Revert to Original" still works.
  - **Favourite** (F).
  - **Set the date** (T), either exact or "year / month only" with the date-approximate convention.
- **Mark:**
  - **To Delete** (D).
  - **Blurry** (B).
  - **To Records** (P): saves the original to your records folder (Google Drive › Personal Records is found automatically). Once saved, it's marked To Delete.
- **Done with this photo:**
  - **Good Enough** (1).
  - **Look at Later** (2).
  - **Everything is in Order!** (3). New passes leave these out by default.
  - **Archive** (A): important to keep, but not to see every day. The app adds the keyword **Archived** in Photos and checks Photos reports it. The keyword is the lasting label: it shows in Photos' Info panel and search, and travels with exports.
    - **Hiding is batched.** macOS asks for confirmation every time an app hides photos, so archived photos stay visible until you click **Hide Archived (N)** in the toolbar (or ⇧⌘H). That hides them all with one confirmation.
    - **Undo (U)** removes the keyword, and unhides the photo if it was already hidden. Unhiding can fail if Photos keeps the Hidden album locked to other apps; then unhide it in Photos › Hidden.
    - The first use asks for permission to control Photos.
- **Move around:** → or Space skips, ← goes back, U or ⌘Z undoes the last action.
- **Passes:** each album or queue remembers where you left off, in a stable shuffled (or date) order. When you've seen everything, start another pass.
- **Deleting** only happens in **Review Deletions**: untick anything to keep, then confirm. macOS asks too, and Photos keeps deleted items in Recently Deleted for 30 days.
- **Health panel** (top right of the photo, H to hide or show): coloured rows for what the app can measure about the photo.
  - **Date:** red for no date (1900), yellow when approximate (redated by year or month, or the "Date approximate" keyword).
  - **Location:** grey for screenshots.
  - **Size:** red under 1 MP, yellow under 2 MP.
  - **Sharpness:** red if marked Blurry, green once you've reviewed it without marking it, yellow before that.
  - **Album:** red in none, yellow only in import or Quick Fix albums.

  Hidden, it shrinks to a slim colour strip. Click the Date row to set the date. Keywords are read from Photos a moment after a photo appears, and also show in the info panel.
- **Albums** (L, or the Album tile).
  - **Recent albums** sit under the health panel, newest first. **⌥1–⌥5** add the photo to one of them; press again to take it back out. ⌘Z undoes.
  - **L** opens the picker, which has the search box ready and lists:
    - **Recent**, with ⌘1–⌘5;
    - **Same day as this photo**: albums that already hold photos from that day;
    - **all albums A–Z**;
    - **New album…** (⌘N), which starts in the folder of your most recent album.
  - In the picker, ⏎ adds or removes, and ⌘⏎ adds and moves to the next photo.
  - Recent albums are the ones you've used in this app. Until you've used a few, they're filled from the albums of photos you reviewed recently.
  - The Quick Fix marker albums are never offered.
- **Right-click the photo** for:
  - **Copy Photo** (also ⌘C): the full-size current version goes on the clipboard. For a video, the file goes on instead, ready to paste into Finder, Messages or Mail.
  - **Copy File Name**.
  - **Show in Photos**, which brings Photos forward on that item.
  - **Add to Album…**, **Set Date…** and **Favourite**.
- **Hidden photos are left out everywhere:** in queues, albums, counts, and the delete and records reviews. A photo you hide in Photos disappears from the app.
- **Albums in Photos:** markers are mirrored into a **Quick Fix** folder in Photos, so they show on your iPhone too. You can turn this off.

The review store is `~/Library/Application Support/PhotoDeFrigifier/review-store.json`, with `actions.jsonl` as an append-only history. The format is in [skills/photo-review-store/SKILL.md](skills/photo-review-store/SKILL.md).

## Build and run

```sh
make run      # build, package .build/apps/PhotoDeFrigifier.app and open it
make test     # unit tests (QuickFixCore)
make check    # plist, tests, build
```

- **Requirements:** macOS 26 and Xcode 26 (Swift 6.2+). No third-party dependencies.
- **Photos access:** the first launch asks for it.
- **Signing:** the app is ad-hoc signed, so macOS may ask for Photos access again after a rebuild. Set `SIGN_IDENTITY="Apple Development: …"` to sign with your own certificate and keep the permission.

**Diagnostics** (read-only): this writes counts and timings to `self-check.json` and quits.

```sh
open .build/apps/PhotoDeFrigifier.app --args --self-check
```

## Layout

| Path | What |
|---|---|
| `Sources/QuickFixCore` | Models, review store, queue ordering, date rules. No PhotoKit, fully unit-tested. |
| `Sources/PhotoDeFrigifierApp` | SwiftUI app: `PhotoLibrary` (all PhotoKit access), `ReviewModel` (actions, undo, keys), views and sheets. |
| `Tests/QuickFixCoreTests` | Swift Testing suite. |
| `skills/` | Reusable Claude skills from the Amazon → Apple Photos migration (below). |

## Claude skills

The `skills/` folder holds what we learned moving an Amazon Photos library into Apple Photos, written as Claude skills:

| Skill | Covers |
|---|---|
| `photo-library-migration` | The end-to-end playbook and safety rules. |
| `amazon-photos-export` | Amazon Photos' private web API: inventory, People, download, completeness proof. |
| `photo-duplicate-finding` | Exact, same-moment, fingerprint and perceptual-hash matching, keeper rules, review tools. |
| `photo-date-repair` | Trustworthy dates, camera clocks, video UTC quirks, placeholder conventions. |
| `apple-photos-automation` | osxphotos, photoscript, PhotoKit, permissions, import recipe. |
| `photo-review-store` | Reading and acting on this app's review store. |

`make install-skills` links them into `~/.claude/skills` so every Claude Code session can use them. `make uninstall-skills` removes the links.
