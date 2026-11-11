# PhotoDeFrigifier: notes for Claude

A SwiftUI macOS app (macOS 26, Swift 6.2 tools, SwiftPM only) for one-photo-at-a-time clean-up of Apple Photos. See README.md.

## Commands

- `make test`: QuickFixCore unit tests (Swift Testing). Run them after any change to Sources/QuickFixCore.
- `make package` / `make run`: build `.build/apps/PhotoDeFrigifier.app` (ad-hoc signed) and open it.
- `open .build/apps/PhotoDeFrigifier.app --args --self-check`: read-only check against the real library. It writes `~/Library/Application Support/PhotoDeFrigifier/self-check.json` and quits. Use it to verify PhotoKit changes, since Claude's shell can't see the app's window.

## Rules

- **The library is the user's real photo library.** Don't test change actions (rotate, date, favourite, album mirroring, delete, export) on it without the user's go-ahead. Read-only checks are fine.
- **Hidden photos are always excluded.** Every library or album fetch uses `PhotoLibrary.visibleOnly()`, and lists are filtered through `summaryByID`, which never contains hidden items.
- **Deletion goes only through `PhotoLibrary.delete`,** behind the delete review sheet and macOS's own confirmation. Never add a silent or bulk delete path.
- **Every change to a review record goes through `ReviewModel.changeRecord`,** or the same pattern: before/after for undo, `store.save()`, `store.log(...)`, album mirroring.
- **Keep QuickFixCore free of PhotoKit** so it stays testable.
- **The review store format** is documented in `skills/photo-review-store/SKILL.md`. If you change `ReviewStoreData` or `AssetRecord`, update that file, keep decoding tolerant of missing fields, and bump `ReviewStoreData.currentVersion` for incompatible changes.
- **`COOKIE.secret`** in the repo root is the user's old Amazon session file. It is gitignored. Never read it.

## Skills

`skills/*` are the user's reusable Claude skills (migration learnings plus the review store). Edit them here; `make install-skills` symlinks them into `~/.claude/skills`.
