# PhotoKit notes for macOS apps (Swift 6, macOS 26)

## Identity

- `PHAsset.localIdentifier` on a Mac is `<UUID>/L0/001`, and that `<UUID>` is the **same UUID osxphotos reports**. Ledgers and lists from osxphotos map straight to PhotoKit with `"\(uuid)/L0/001"`.
- Local identifiers are specific to one library. Use `PHPhotoLibrary.cloudIdentifierMappings(forLocalIdentifiers:)` to match items across devices.

## Access

```swift
let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)   // .authorized / .limited / .denied
```

- macOS has no read-only access level; `.readWrite` is it.
- With `.limited` you can't see the whole library, so treat it as not authorized for any whole-library work.
- Check `PHPhotoLibrary.shared().unavailabilityReason == nil`.

## Enumerating

```swift
let opts = PHFetchOptions()
opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
let all = PHAsset.fetchAssets(with: opts)            // lazy; ~10k assets enumerate in about a second
```

- **Hidden and burst items:** set `includeHiddenAssets` and `includeAllBurstAssets` if you need them.
- **Useful properties:** `creationDate`, `mediaType`, `mediaSubtypes` (`.photoLive`, `.photoScreenshot`, …), `pixelWidth`, `pixelHeight`, `duration`, `isFavorite`, `location`, `hasAdjustments`.
- **Original filename:** `PHAssetResource.assetResources(for:)`, then `originalFilename` on the `.photo` or `.video` resource.
- **Albums:** `PHCollectionList.fetchTopLevelUserCollections(with:)`. Recurse with `PHCollection.fetchCollections(in:options:)`.
- **Albums containing one asset:** `PHAssetCollection.fetchAssetCollectionsContainingAsset(asset, with: .album, options: nil)`.
- **Keeping up to date:** register a `PHPhotoLibraryChangeObserver` and apply `change.changeDetails(for: fetchResult)` to the result you hold, rather than re-reading everything. The callback arrives on a background queue.

## Images and video

- **Images:** use `PHCachingImageManager.requestImage(for:targetSize:contentMode:options:resultHandler:)` with `isNetworkAccessAllowed = true` (iCloud-optimised libraries keep originals in the cloud).
  - The handler can fire twice; skip results where `PHImageResultIsDegradedKey == true`.
  - `.fastFormat` and `.highQualityFormat` each fire once.
  - Use one fixed target size, so that `startCachingImages` prefetches hit the cache.
- **Video:** `requestPlayerItem(forVideo:options:)`, then play it with `AVPlayer`.
- **To avoid downloading:** set `isNetworkAccessAllowed = false`. A `PHPhotosError.networkAccessRequired` error then means the original is in iCloud only.

## Changes (all inside `performChanges`; capture only Sendable values, re-fetch assets inside)

```swift
try await PHPhotoLibrary.shared().performChanges {
    guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
    let r = PHAssetChangeRequest(for: a)
    r.creationDate = newDate        // Photos' date
    r.isFavorite = true
}
```

- **Albums:**
  - Create an album with `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`.
  - Create a folder with `PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle:)`.
  - Put an album in a folder with `addChildCollections([placeholder])`.
  - Change an album's contents with `PHAssetCollectionChangeRequest(for:)?.addAssets`/`removeAssets`.
- **Delete:** `PHAssetChangeRequest.deleteAssets(fetchResult)`.
  - macOS always shows its own confirmation dialog, and items go to Recently Deleted for 30 days.
  - If the user cancels, `performChanges` throws `PHPhotosError.userCancelled`. Treat that as "nothing happened".
- **Rotate as an edit you can revert:**
  1. Call `requestContentEditingInput`. Set `canHandleAdjustmentData` to return true only for your own format, so the input gives you the unedited original.
  2. Apply `fullSizeImageOrientation` plus your rotation with `CIImage.oriented(_:)`. `.right` turns 90° clockwise and `.left` 90° anticlockwise.
  3. Write JPEG or HEIC to `output.renderedContentURL(for:)`. Pick a type from `supportedRenderedContentTypes`.
  4. Set `PHAdjustmentData(formatIdentifier:formatVersion:data:)`, then assign `contentEditingOutput` in `performChanges`.
  5. If the total rotation comes back to 0°, call `revertAssetContentToOriginal()`.
  6. If someone else already edited the photo (Photos' own crop, say), you get the rendered image and your edit builds on top of it. "Revert to Original" in Photos undoes both.
  7. Live Photos need `PHLivePhotoEditingContext`, and videos need an AVFoundation export.
- **Hide:** set `PHAssetChangeRequest(for:).isHidden = true`. To find hidden items, fetch with `includeHiddenAssets = true`. When Photos keeps the Hidden album locked (the default), other apps may not see hidden items at all, so unhiding from an app can fail. osxphotos (`query --hidden`, `export --hidden`) still reads them from the database.
- **Not available:** keywords, titles, captions and People. On macOS, AppleScript (`tell application "Photos"`) can set `keywords`, `name` and `description`, but Photos must be running and the user must grant Automation.
  - Address a photo with `media item id "<UUID>/L0/001"`, which is exactly the PhotoKit local identifier.
  - From an app, run `/usr/bin/osascript` with the script lines as `-e` arguments and the values as arguments read by `on run argv`. That avoids building script text from data.
  - Run it off the main thread with a timeout.
  - Add `NSAppleEventsUsageDescription` to the Info.plist. The first call brings up the Automation prompt, and error -1743 means it was refused.
  - `keywords` is `missing value` when there are none.

## Swift 6 concurrency

- PhotoKit classes aren't `Sendable`. Keep the library object on the `@MainActor`.
- **Image and player callbacks:** bridge them with `withCheckedContinuation`. Wrap non-Sendable results in a small `@unchecked Sendable` box.
- **Change blocks:** pass identifiers (strings) into `performChanges` and fetch the assets again inside the block.
- **Heavy rendering:** do it in `Task.detached` with URLs only.
