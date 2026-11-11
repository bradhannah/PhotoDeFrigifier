---
name: amazon-photos-export
description: Get a complete, verified copy of an Amazon Photos / Amazon Drive library (file inventory with MD5s, People names, favourites, albums and the original files) through Amazon's private web API, run from inside the user's signed-in browser tab. Use this whenever someone wants to export, download, back up, audit, count or leave Amazon Photos, pull People or face names or checksums out of it, or when the web app's own Download button refuses ("too many files", "over 5 GB"), even if they never say "API".
---

# Amazon Photos export

Amazon has no public Photos API. The web app calls `https://www.amazon.<tld>/drive/v1/...`. Everything below was worked out from that and checked on amazon.ca in September and November 2026. Treat it as fragile:
- Probe every call with `limit=1` first.
- Prove completeness with counts and MD5s. Don't trust a run just because it finished.

## Ground rules

- **Read-only.** Use only GET requests. Never call anything that moves, trashes, renames or edits.
- **Keep the secret in the page.** Run requests inside the user's own signed-in tab, so the session never leaves the browser.
  - Never ask for cookie values, and never print, store or log them.
  - An older approach pasted the whole Cookie header into a local `COOKIE.secret` file. If you meet one, never open it, and keep `*.secret` in `.gitignore`.
- **Errors leak data.** Amazon echoes your filter text (filenames, dates) in error messages. Summarise errors rather than pasting them into shared reports.
- **Use the user's own region.** Use amazon.com, .ca, .co.uk, .de and so on. Cookie names give a hint: `at-main` means the US store, and `at-acb<cc>` means that country.
- **Watch for sensitive files.** Amazon Drive often holds more than photos: PC backups, app downloads, and sometimes password-manager emergency kits or recovery-code files. Point them out to the user by name, never open them, and suggest moving them into a password manager or an encrypted disk image.

## Authentication inside the page

```js
const sid = (document.cookie.match(/(?:^|;\s*)session-id=([^;]+)/) || [])[1];
const api = (path, params = {}) =>
  fetch(`/drive/v1/${path}?` + new URLSearchParams({ resourceVersion: 'V2', ContentType: 'JSON', ...params }),
        { credentials: 'include', headers: { accept: 'application/json', 'x-amzn-sessionid': sid } })
    .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
```

- `credentials: 'include'` on its own returns **401**. The header `x-amzn-sessionid` (set to the `session-id` cookie value) is what makes the request work.
- **401 or 403** means signed out or expired. Stop, and ask the user to sign in again in that tab. `401 No Auth Method Provided` is the expired-cookie case.
- **400** means the request shape is wrong, not an auth problem.

[scripts/amazon_inventory.js](scripts/amazon_inventory.js) is a ready-made inventory runner. It runs in the background of the page and you poll its progress, because the browser tool times out after about 45 s.

## Endpoints

| Purpose | Call | Notes |
|---|---|---|
| Totals and People list | `search?asset=NONE&filters=type:(PHOTOS OR VIDEOS)&limit=1&searchContext=customer&groupByForTime=year` | `count` is the total. `aggregations` include `allPeople`, `people`, `favorite`, `location`, `time`, `type`, `captureDevice`, `things`. Asking for the `people` category on its own returns 400, so use this broad call instead. |
| **Full file inventory** | `nodes?filters=kind:FILE&limit=200&startToken=<nextToken>` | Reliable: 16,500 files in 83 pages with no duplicates. Use `kind:FOLDER` for folders. |
| Folder contents | `nodes/{id}/children?limit=200&startToken=...` | Walks one folder tree. |
| Photos-view search | `search?asset=ALL&filters=type:(PHOTOS)&limit=100&offset=N&searchContext=customer&sort=['createdDate DESC']` | Pages by offset; read the warning below first. |
| One person's photos | same search with `filters=type:(PHOTOS) AND people:(<match>)` | `<match>` comes from the aggregation entry. |
| Favourites | `filters=... AND favorite:(true)` | |
| Albums | nodes with `kind:VISUAL_COLLECTION`, and their `children` | |
| Account and root | `account/usage`, `nodes?filters=isRoot:true` | `data[0].ownerId` is the account ID needed for downloads. |
| **Download one file** | `nodes/{id}/contentRedirection?querySuffix=%3Fdownload%3Dtrue&ownerId={ownerId}` | Redirects to `content-na.drive.amazonaws.com` and returns the original bytes. `nodes/{id}/content?download=true` returns 404. |

**Fields worth keeping from each node:**
- `id`, `name`, `kind`, `parents[]`, `status`, `ownerId`, `createdDate`, `modifiedDate`, `settings.favorite`, `keywords[]`
- `contentProperties.{md5, size, contentType, extension, contentDate}`
- `contentProperties.image.{width, height, dateTimeOriginal, make, model, location}`

### Paging

`/search` with `offset` paging can repeat some items and skip others. One run with `asset=ALL`, `limit=200` and a contentDate sort returned 6,708 rows but only 6,244 unique IDs. Another run with `type:(PHOTOS)`, `limit=100` and a createdDate sort came out exact.

Whichever call you page through:
- Check that `count` stays the same on every page.
- Check that the number of unique IDs equals `count`.
- Throw the partial result away if either check fails.

For the authoritative inventory, page `/nodes` with `startToken`, not `offset`. Pause 200 to 250 ms between calls; that pace never hit a rate limit.

### Search filter limits

- MD5 is returned but you can't search by it. `contentProperties.md5:` returns 400.
- Only `type:(PHOTOS) AND <one field>:<value>` works. Combining `name:` with `createdDate:` returns 400.
- To look up a single photo, require `count == 1` plus a matching `id` and `md5` before trusting the result.

## People names

1. Take the aggregation entries in `allPeople` and `people`. Each has `match` (an ID), `count` and `searchData.clusterName`. Unnamed clusters have no `clusterName`; skip them.
2. Page each person's photos with `people:(<match>)`. Check that the unique IDs equal that person's `count`. The result is a photo-to-names map.
3. Search results for a single photo come back with empty People facets. Always build the map person by person.
4. Amazon only scans faces for items in the main Photos view, not for files in backup folders.
5. Use Amazon's spelling of a name, which can differ from the user's.

People names can't be written into Apple's People album. Carry them over as keywords instead (see the `apple-photos-automation` skill).

## Downloading originals in bulk

The web app's Download button refuses folders over 5 GB or over 1,000 files. What worked:
1. Walk the tree, then fetch with 4 parallel workers and up to 4 retries. Check that `byteLength === size` for every file.
2. Pack the files into a tar archive in JavaScript, using PAX headers for long or non-ASCII paths.
3. Save each 300 to 650 MB part through a blob `<a download>` link.
4. Wait until the file has landed (poll `ls ~/Downloads`), then free the memory before building the next part.

Throughput was about 5 MB/s. Don't hold more than about 4 GB of blobs in the page.

**Known bug:** files whose names contain a comma fail with `TypeError: Failed to fetch`. Log them as unfetchable. Amazon's desktop app is the only other way to get them.

### Downloading in the Claude desktop app's browser pane

- Every save needs the user to click Allow in the pane. If the pane is hidden or nobody clicks, later downloads stall without any error. Ask the user to watch for the prompts.
- While a download is in progress it is a hidden temp file in Downloads (`.<random>…com.anthropic.claudefordesktop…`). A finished one sometimes never gets renamed. Copy it out and verify it by MD5.
- Quitting the app clears stuck downloads, but it loses everything held in page memory and signs the user out of Amazon.

## Proving completeness

1. Build a manifest of `{id, path, md5, size}` from `/nodes`.
2. Hash the download in a single process: `find <root> -type f -exec md5 -r {} +`. Parallel runs interleave their output.
3. Compare the two and write a `still_missing.json`. Fetch only the missing files, then compare again.
4. Look beyond the Photos view: Folders, Trash and the Family Vault. A Photos-view-only download missed almost every file from 2016 to 2024 in one library.

## Dates and names

- **`contentDate`** is local wall-clock time wrongly labelled `Z`. Don't convert it from UTC.
- **File modification times** after a download mean nothing. In one library, 1,627 files shared one timestamp.
- **Name suffixes:** when names collide, Amazon adds ` (2018-02-07T18_23_09.872)` or ` (2)` to the name. That timestamp is the upload time, not when the photo was taken. Strip it before parsing dates from filenames or comparing file stems.

## Related skills

- `photo-duplicate-finding`: what to do with the download next.
- `photo-date-repair`: fixing dates.
- `photo-library-migration`: the whole move into Apple Photos.
