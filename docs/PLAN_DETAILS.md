# PhotoDeFrigifier Plan Details

Last verified: 2026-09-02

This is the durable record of product decisions, provider capabilities, risks,
and implementation gates for PhotoDeFrigifier. Update it whenever a provider
probe changes a fact or an implementation decision changes.

## Evidence Labels

- **Supported**: documented public behavior from the provider.
- **Observed**: behavior reproduced by a local probe or representative sample.
- **Experimental**: undocumented behavior that may fail without notice.
- **Unknown**: a representative sample or focused test is still required.
- **Decision**: an intentional project choice, with a revisit trigger where useful.

## Objective

Build a local-first macOS application that reconciles Apple Photos, Google
Photos, Amazon Photos, and loose files. The intended end state is:

- Apple Photos is the primary day-to-day library.
- Google Photos is a secondary backup for cloud-appropriate media.
- Private media can use Apple Hidden when iCloud storage is acceptable.
- Never-cloud media is kept outside photo services in an established encrypted,
  versioned backup repository.
- Originals and source-specific metadata remain recoverable.

The initial personal library is expected to contain fewer than 10,000 logical
items before duplicates across providers are counted.

## Locked Decisions

| Area | Decision | Rationale | Revisit trigger |
| --- | --- | --- | --- |
| Platform | Native SwiftUI app targeting macOS 26+ | Best Apple Photos integration and acceptable personal-first scope | A concrete non-macOS requirement |
| Repository | Public GitHub-ready source, personal-first behavior | Keep decisions auditable and reusable | None |
| Storage | Exports and staging live on an external disk | Internal disk has only about 25 GiB free | Internal capacity changes materially |
| Originals | Never modify source originals | Hash stability and safe rollback | Never; create annotated transport copies instead |
| Metadata | XMP sidecars plus a lossless JSONL manifest | XMP is portable but cannot represent every provider assertion | A demonstrably better open interchange format |
| Catalog | Versioned private JSONL snapshots containing raw observations and derived entities | Keeps the first implementation auditable, portable, and dependency-free | Query volume demonstrates a need for an indexed database |
| Deduplication | Auto-merge only byte-identical, resource-compatible occurrences | Avoid collapsing edits, bursts, RAW pairs, or recompressed copies | Never weaken without measured false-positive evidence |
| Deletion | No source/provider deletion in v1 | Migration must be reversible and independently audited | After verified backups and a separate deletion design |
| Apple | Primary library | Best local integration and user preference | User decision |
| Google | Secondary backup, initially browser-assisted | Full existing-library APIs are no longer available | Register a Google OAuth client for automated uploads |
| Sensitive media | Explicit Apple and Google routes, plus mandatory archives | Apple Hidden, cloud exclusion, and archive recovery are independent choices | User decision |
| Amazon | Isolated read-only cookie probe, then export fallback | No supported consumer Photos API exists | Amazon publishes a supported API |
| Auth | Registration-free hybrid initially | Avoid provider developer-client setup | Automated Google uploads become worth registration |

## Authorization Terminology

A normal website login creates a private browser session. Another application
cannot normally reuse that session. OAuth 2.0 is the provider-approved mechanism
for granting an application API access. OpenID Connect adds user identity on top
of OAuth 2.0. Both require the application to have a provider-issued client ID.

Photo access does not use one uniform OIDC mechanism:

| Provider | Registration-free path | Registered path | What grants photo access |
| --- | --- | --- | --- |
| Apple | PhotoKit permission dialog | Sign in with Apple | PhotoKit only; Apple sign-in grants identity, not Photos |
| Google | Takeout, direct transfer, manual upload | Google OAuth 2.0 | Takeout/export or limited Photos API scopes |
| Amazon | Manual export or temporary browser-session cookies | Login with Amazon | Export/cookies; LWA grants profile data, not Photos |

### Registration-Free Consequences

- Apple PhotoKit can be tested and used fully for supported local operations.
- Google Takeout and Google-to-iCloud transfer can be opened in the browser and
  their results can be inspected locally.
- A Google-ready export can be uploaded manually through Google Photos or Google
  Drive for desktop.
- Amazon's undocumented API can be tested with temporary browser-session cookies.
- Sign in with Apple, Login with Amazon, Google Picker, and Google Library APIs
  cannot be authorized without app registration.
- Google OAuth remains a documented, disabled extension point.

## Provider Capability Matrix

### Apple Photos

**Supported**

- Access is local PhotoKit authorization through `PHPhotoLibrary`, not OIDC.
- Public PhotoKit exposes assets, media types, dates, location, dimensions,
  duration, favorite state, hidden state, and album membership.
- `PHFetchOptions.includeHiddenAssets` can request hidden assets.
- `PHAssetResource` exposes original and related resource roles, filenames,
  content types, dimensions, and sometimes byte size.
- `PHAssetResourceManager` can retrieve originals, RAW resources, paired Live
  Photo videos, edited resources, and adjustment data.
- `PHAssetCreationRequest` can reconstruct assets from resource sets.
- `PHAssetChangeRequest` on macOS 26 can set creation date, location, favorite,
  and hidden state.
- Hidden media is absent from normal library views and the Hidden album is locked
  by Touch ID or the macOS login password.
- Hidden media remains in Apple Photos and syncs through iCloud Photos.

**Supported only on macOS 27 and later**

- `PHAssetExtendedMetadata` caption and keyword reads.
- Public caption, keyword, and rating writes through `PHAssetChangeRequest`.

**Unsupported by public PhotoKit**

- Current named People clusters and face rectangles.
- Writing People identities into Apple's native People system.

**Experimental/optional**

- `osxphotos` can read Apple Photos database metadata including people, faces,
  face regions, titles, descriptions, keywords, albums, and edit information.
- `osxphotos` is MIT licensed and must be treated as a read-only enrichment
  adapter because the Photos database schema is private.
- Apple Events may write titles, descriptions, and keywords on macOS 26. This
  requires a focused lab probe and must never write directly to the database.

### Google Photos

**Supported**

- Google Photos APIs require OAuth 2.0 user authorization; service accounts are
  not supported.
- Since March 31, 2025, the Library API can list and edit only content created by
  the requesting application.
- `photoslibrary.appendonly` can upload bytes and create media/albums.
- `photoslibrary.readonly.appcreateddata` can read app-created media/albums.
- `photoslibrary.edit.appcreateddata` can edit app-created descriptions and album
  organization.
- Picker API scope `photospicker.mediaitems.readonly` grants access only to media
  explicitly selected by the user in a Picker session.
- Google Takeout remains the practical complete-library export.
- Takeout preserves extra provider metadata in JSON sidecars.
- Google can transfer a copy directly to iCloud Photos without local staging.

**Direct-transfer limitations**

- Locked Folder content is omitted.
- Manually edited metadata is omitted.
- The video portion of Motion Photos and Live Photos is omitted.
- Trash, unsaved memories/creations, broken media, and unsupported formats are
  omitted.
- Repeating transfers may create duplicates.
- Apple reports that filename, description, type, and location metadata can be
  transferred, but the result still requires reconciliation.

**Unavailable through supported APIs**

- Full inventory of an existing user library.
- Native face groups and People names.
- Existing favorites, archive state, or Locked Folder state.

**Decision**

- Use Takeout as the inventory baseline.
- Use browser-assisted transfer/upload initially.
- Add Google OAuth only when automated app-created backup uploads justify a
  Google Cloud project, consent screen, client ID, and verification burden.

### Amazon Photos

**Supported**

- No public consumer Amazon Photos API has been identified.
- Login with Amazon supports profile scopes such as user ID, name, email, and
  postal code; these scopes do not grant Amazon Photos access.
- Manual download/export remains the dependable fallback.

**Experimental**

- The open-source `amazon_photos` project uses temporary Amazon website cookies
  against undocumented `/drive/v1` endpoints.
- Its source demonstrates endpoints for root/usage/search, downloads, favorite
  and hidden state, albums, people aggregations, and cluster operations.
- Search responses can contain provider IDs, filenames, dates, dimensions,
  byte size, content type, and MD5.
- Aggregations may expose people-cluster names/IDs and search may expose cluster
  membership. Face rectangles are not proven.
- **Observed 2026-08-31**: the legacy specific aggregation category `people`
  returned HTTP 400 with `Unsupported aggregation category: people`. The lab now
  requests the broad aggregation shape from `/search` and discovers currently
  available category field names without assuming that legacy category.
- The `/nodes` endpoint has a documented-in-code 9,999 node window. Search
  pagination behavior must be tested separately.
- Existing issue reports show expired cookies, `401 No Auth Method Provided`,
  regional host/cookie problems, and unmerged implementation bugs.

**Observed 2026-08-31 with a Canadian account**

- Regional cookie inference selected `www.amazon.ca` and the broad `/drive/v1/search`
  aggregation request returned HTTP 200.
- The response included a complete aggregate inventory count, demonstrating that
  the search path can inventory this account without downloading media.
- Current aggregation categories include `allPeople`, `people`, `clusterId`,
  `familyMembers`, `favorite`, `location`, `things`, `time`, `type`,
  `captureDevice`, and `captureMode`.
- People aggregation entries expose `count`, `match`, `searchData`, and
  `searchData.clusterName`. A live probe confirmed that a `match` value is
  accepted by the `people:(match)` search filter and returns a photo containing
  that named person. The long-term stability of this undocumented identifier
  remains unknown.
- Location aggregations expose city, state, state code, country, country ISO-3
  code, and a location identifier.
- Media nodes expose content type, extension, byte size, MD5, image dimensions,
  content signatures and signature types, created/modified dates, keywords,
  labels, parent relationships, protection/restriction flags, and provider IDs.
- The response includes `nextToken`, which may provide token-based pagination
  beyond the older offset/window behavior. Continuation must be tested before
  relying on it.
- The legacy specific aggregation endpoint rejected category `people`, while the
  broad search response still included both `people` and `allPeople` aggregation
  data. Broad capability discovery is therefore more reliable than assuming
  specific legacy category names.
- Provider Access Lab includes a bounded **People on Latest Photo** probe. It
  fetches one latest photo and tries separate exact `createdDate` and `name`
  lookups, then requires one matching provider ID and MD5 before accepting
  aggregation facets. All lookup values remain in memory. Names and keywords use
  a separate non-`Codable` model and never enter copied/exported `ProbeResult`
  reports.
- **Observed 2026-08-31**: filtering on `contentProperties.md5` returned HTTP 400
  with `Invalid fieldName to search on: contentProperties.md5`. MD5 is returned
  metadata but is not currently a searchable field, so it is now used only to
  verify the supported-field lookup result.
- **Observed 2026-08-31**: the exact lookup using `name:"..."` and an ungrouped
  `createdDate` returned HTTP 400 with `Invalid filter ... Cannot be parsed`.
  A second combined lookup using parenthesized `name` and `createdDate` values
  produced the same parse failure. The probe now avoids the unverified combined
  grammar and tries at most two documented single-field forms: exact
  `createdDate`, then exact `name`. Either response must contain exactly one node
  matching the original in-memory provider ID and MD5. The filename form is now
  live-verified; the creation-date form remains unverified.
- Amazon reflects the full rejected filter, including filename and date, inside
  error messages. Sanitized reports now map these responses to the fixed text
  `Invalid filter syntax.` and never copy the reflected query.
- **Observed 2026-08-31**: the single-field exact filename fallback returned
  HTTP 200 and its one node matched the original in-memory provider ID and MD5.
  For that latest photo, `people`, `allPeople`, and `clusterId` were empty and no
  keywords were returned. This validates the narrow lookup but does not test a
  photo known to contain a recognized face.
- Provider Access Lab now offers a separate **Find Recognized Photo** probe. It
  selects one named global People facet in memory and uses the documented
  `people:(cluster-id)` filter to request one matching photo. The confirmed name
  is local-only, the cluster/photo identifiers are discarded, and the report
  warns that one facet relationship does not enumerate every co-person.
- **Observed 2026-08-31**: **Find Recognized Photo** returned a matching photo and
  displayed its selected People name locally. This confirms a working read-only
  path from `aggregations.people[].match` and `searchData.clusterName` to photo
  membership on the tested Canadian account.
- **Find Recognized Photo** now accepts an exact local person name, reports the
  total matching photo count returned by `people:(match)`, and performs one exact
  follow-up on the sampled photo to inspect co-People facets. The selected name,
  all returned names, and lookup identifiers stay in the non-`Codable` in-memory
  result model.
- **Observed 2026-08-31**: an exact local person-name selection matched one facet
  and Amazon reported 762 photos for that cluster. The exact sampled-photo
  response exposed one named People facet. Sanitized reports now explicitly say
  whether exactly one local name matched while continuing to omit the name.
- Gathering every matching photo is technically possible by paginating the same
  `people:(match)` query. Recording all people per photo can be built either from
  exact-photo facets, if the co-People check proves complete, or by inverting the
  node-ID sets returned for each named People cluster. Co-People completeness
  and a full end-to-end paginated run require verification before promotion.
- **Observed 2026-08-31**: the person-filtered search reported 762 matching
  photos. It did not return a usable `nextToken`, but offset pages 0 and 25 each
  returned 25 unique node IDs with zero overlap. The IDs were compared in memory
  and discarded. This validates offset pagination for gathering the complete
  selected-person photo set up to the reported count; larger runs still need
  rate limiting and end-to-end count verification.
- **Observed 2026-08-31**: a complete `type:(PHOTOS)` live pass exported 6,300
  unique raw photo nodes across 63 offset pages of 100, with zero duplicate page
  entries and exact agreement with Amazon's reported count. The previous 6,453
  broad aggregate represented a wider media scope than photos alone.
- A second complete live pass inverted all named People facets. It exported 2,269
  photo-person memberships across 24 named People clusters, producing 8,598
  JSONL records including manifest, account usage, root metadata, raw
  aggregations, photo nodes, People records, memberships, and final summary.
- The **Complete private metadata export** streams raw provider node dictionaries
  so unknown fields are preserved. It writes to a mode-`0600` temporary sibling,
  verifies stable counts and unique IDs, and moves the file into place only when
  the full photo and requested People inventories validate. Partial files are
  discarded. Cookies, request URLs, and continuation tokens are never written.
- This JSONL is intentionally private rather than sanitized. It can contain
  filenames, dates, hashes, signatures, provider/owner IDs, parent relationships,
  locations, device/EXIF details, labels, keywords, restrictions, favorite state,
  People names, cluster keys, and photo-person memberships. Users must choose an
  encrypted or otherwise private destination. No image bytes are downloaded.
- The private export uses two explicit steps. First, a local file picker accepts
  at most 64 KiB of UTF-8 Cookie-header text and validates required Amazon
  authentication cookies (or the user can paste into the masked field). Second,
  a directory picker creates a timestamped `amazon-private-photo-inventory-…`
  JSONL file inside the selected encrypted/private folder. The cookie source
  path and contents are never copied into the inventory and the in-memory value
  is cleared after starting the export.
- The exact filtered aggregation behavior remains unverified. A successful live
  run must confirm whether `people`, `allPeople`, or `clusterId` represents
  membership for one photo rather than a global facet list.

**Decision**

- The Amazon probe is a separate lab component, never a production dependency.
- It is read-only, disabled by default, rate-limited, and restricted to an
  audited GET endpoint allowlist.
- Authentication/session cookies remain in memory and are cleared after each probe.
- Regional `at-acb` cookie names override the fallback host selection.
- The lab does not automate browser-cookie extraction.
- Full pass means an optional read-only adapter; partial pass means metadata
  enrichment plus manual-export bytes; failure means export-only ingestion.

## Canonical Data Model

The reconciliation model separates logical media, underlying byte resources,
provider occurrences, and metadata claims.

### Asset

One logical photo, video, Live Photo, RAW+JPEG capture, or edited item.

### Resource

One byte stream associated with an asset, including:

- Primary photo or video.
- RAW or alternate photo.
- Live Photo paired video.
- Full-size edited photo/video.
- Adjustment data or adjustment base.

Each available resource records SHA-256, byte size, media/content type,
dimensions/duration, role, original filename, and availability.

### Source Item

One occurrence in Apple, Google, Amazon, or a filesystem export. It records the
provider identifier, import run, source path when applicable, state flags, and a
sanitized/raw provider assertion payload that never contains credentials.

### Metadata Assertion

A typed value plus field name, source item, provenance, observed date,
confidence, and whether it appears user-authored or inferred. Canonical values
are resolutions over assertions, not destructive replacements.

### Relationships

- Album and album membership.
- Person identity and aliases.
- Face regions using normalized coordinates when known.
- Match candidates and explicit merge decisions.
- Operation plans and receipts for resumable migrations.

### Implemented Catalog Foundation

- `PhotoCatalogCore` is independent of PhotoKit and the experimental cookie lab.
- The current canonical JSONL schema is version 4. Schema-2 catalogs are migrated
  on read by reconstructing explicit current-run pointers; schema-2 and schema-3
  resources are considered current only when existing byte evidence binds them to
  the owning item's latest observation. Other legacy resources remain
  historical/unknown until rescan rather than receiving fabricated provenance.
  New scans bind each resource to the exact observation that contained it, so
  resources removed from a later compound item remain historical rather than
  current match evidence. Locally measured MD5 remains absent until a source is
  measured again. The Amazon private-JSONL adapter is version 3; format or
  interpretation changes require version bumps.
- Stable source identity is scoped by source library and provider external ID.
- Import runs retain adapter/version, source schema, capture time, record count,
  source library, and SHA-256 of the source inventory. All of those fields scope
  idempotence so an adapter revision can reinterpret unchanged source bytes.
- Source JSONL is hashed during the same file-descriptor pass that parses its
  records. A size or modification-time change during that pass rejects the run.
- Source observations retain every raw JSON record, record type, line number,
  import run, and source-item relationship when one exists.
- Normalized metadata claims use typed values and retain raw value, source JSON
  path, authorship, confidence, observation, source item, and import run.
- Amazon People clusters, display-name claims, and memberships remain
  source-scoped and provenance-bearing. Equal names do not imply one
  cross-provider person.
- Reimporting an unchanged source fingerprint is idempotent. Importing a changed
  inventory updates the source item's latest observation while preserving prior
  observations and claims.
- Canonical JSONL writes use a mode-`0600` temporary sibling, validate references
  and record counts, append a completion summary, synchronize the file, atomically
  replace the destination, and synchronize the containing directory.
- Catalog updates use both an in-process lock and an adjacent mode-`0600` file
  lock so concurrent app windows or processes cannot lose one another's runs.
- The production app creates a `.photodefrigifier` Library Project package. Its
  mode-`0600` manifest records source identity, import status, and security-scoped
  bookmarks; its canonical catalog remains a separate private JSONL file inside
  the package.
- Library Project schema 2 allows one Amazon inventory to own several attached
  download-folder sources and persists a Google-ready export destination plus two
  independently identified archive destinations. Schema-1 manifests migrate in
  memory and are rewritten only after a later project update.
- Project imports are serialized with a package lock and a private pending-import
  journal. Opening a project recovers an interrupted manifest update from the
  already-committed catalog before returning one locked manifest/catalog view.
- Explicit match decisions, canonical people, source-person assignments, and
  destination-specific person routes are stored separately in an atomic
  mode-`0600` `review.json`. Review schema 2 records Apple `Visible`, `Hidden`, or
  `Exclude` and Google `Include` or `Exclude`; schema-1 privacy categories migrate
  conservatively. Legacy candidate-level duplicate decisions remain historical
  but require current pair review because they were not bound to observations.
  Provider evidence remains unchanged when review state changes.
- The filesystem adapter version 2 recursively inventories ordinary photo/video folders,
  skips hidden entries, symlinks, and package descendants, streams each regular
  file through SHA-256 and MD5, measures byte length, and reads available embedded
  image dimensions and selected EXIF/TIFF/GPS claims. Extension recognition
  includes QuickTime, WMV, and SVG, with ImageIO signature fallback for images
  whose filename extension is misleading. It never modifies source files or
  substitutes filesystem modification time for capture time.
- Folder-relative paths remain source occurrence identifiers and preserve
  hierarchy without automatically becoming albums. Changed bytes preserve the
  occurrence while replacing its current verified-resource link; prior verified
  bytes remain in the catalog as evidence.
- Each source library records its explicit current import run. Items absent from
  a later complete scan remain as historical evidence but are excluded from
  automatic and reported-digest matching. Returning to an earlier fingerprint
  restores that run as current rather than discarding the rescan as a duplicate.
- A local SHA-256 verification is bound to the exact source observation whose
  bytes were read. A newer observation makes that verification ineligible for
  automatic matching until the bytes are measured again.
- The production app can create/open a Library Project; add, replace, or rescan a
  folder; import a completed Amazon inventory; attach several downloaded-media
  folders to that inventory; and inventory the system Apple Photos library after
  full PhotoKit authorization. It does not access Amazon cookies. Google
  production import remains visibly staged but unavailable.
- The dependency-free `ApplePhotosAdapter` includes hidden and burst assets,
  inventories user and smart album memberships, maps PhotoKit resource roles,
  and measures locally available resources with SHA-256 and MD5 while explicitly
  disabling network access. iCloud-only and unreadable resources remain cataloged
  without byte evidence and are reported separately.
- An Apple source retains a bounded set of PhotoKit local-identifier anchors.
  Rescans must overlap those anchors; switching the system library or opening the
  project on a Mac with unrelated identifiers is rejected instead of merging
  unrelated library-scoped identifiers under the existing source.
- Matches presents side-by-side, memory-only previews for exact SHA-256, Amazon
  MD5/type/size, normalized exact-filename, and matching-filename-stem evidence.
  Pair decisions include both resource and current observation IDs, every
  unordered pair is reviewed in bounded groups, exact-byte pairs are automatic,
  and contradictory transitive decisions block planning. Confirmed relationships
  can propagate source People memberships to canonical PhotoDeFrigifier people.
  Public PhotoKit does not expose or modify Apple's native People identities.
- Filesystem previews walk beneath a security-scoped root using descriptor-relative
  opens without following symlinks, verify cataloged SHA-256 before decode, and
  detect changes while decoding. Apple previews are local-only PhotoKit asset
  renditions and are labeled as such rather than represented as resource-specific.
  Amazon inventory previews are explicitly labeled proxies backed by attached
  local candidates. Preview caching is memory-only and byte-bounded.
- Destinations and Review are always available. Review derives one conservative
  retained representative only when every current resource in two compound
  assets has a one-to-one established match, applies the most restrictive person
  route, and reports duplicate, person, Amazon-download, destination, and archive
  blockers. No destructive or provider write operation is implemented.
- **Observed 2026-09-01**: the retained 8,598-record private Amazon inventory
  imported and round-tripped successfully as 6,300 provisional assets, 68,375
  typed claims, 24 source-scoped People clusters, and 2,269 memberships.
- The same import produced 44 provider-MD5 candidate groups and zero automatic
  matches because no media bytes have yet been read for local SHA-256.

## Matching Policy

### Automatic

- Stream each available file through SHA-256.
- Merge occurrences only when compatible resource roles have identical hashes.
- Keep compound resources together for Live Photos, RAW+JPEG, and edit stacks.
- A verified byte resource must record locally measured SHA-256, measured byte
  length, and verification time. Provider-reported digests cannot create it.

### Review Required

- Perceptual image hashes.
- Video duration/key-frame similarity.
- Matching timestamps, dimensions, camera data, or normalized filenames.
- Same visual content with different encodings or metadata blocks.
- Edited derivatives, bursts, and provider-generated copies.
- Provider-reported MD5 or SHA values, even when reported sizes also agree.
- Amazon-reported MD5 plus byte length may be bridged to a locally measured MD5
  only as a persisted user review decision. If one MD5-and-size group contains
  multiple distinct local SHA-256 values, it is withheld as ambiguous rather than
  offered for confirmation.
- Exact filenames are compared case-insensitively after Unicode normalization and
  only across compatible media/resource classes. Matching stems across extensions
  form a lower-confidence tier. Both tiers require explicit pair review.
- Pair decisions are valid only for the current observations. A rescan that creates
  a new observation makes an earlier decision inapplicable until reviewed again.
- Amazon MD5 groups create only local-to-Amazon review pairs. Two Amazon inventory
  records never use the same unconfirmed local proxy as evidence against each
  other, and resources belonging to one source item are never compared as
  duplicates.
- Filename groups above 100 occurrences, or review groups that would exceed the
  global 20,000-pair budget, are not expanded quadratically. They remain visible
  and block readiness until source scope or naming is narrowed. Large exact-byte
  groups use a linear identity graph; Amazon MD5 groups compare one local
  representative per source library with each Amazon occurrence.

## Metadata Portability

Original bytes are immutable. Portable exports place sidecars adjacent to an
exported copy and bind every sidecar/manifest record to a resource SHA-256.

Planned XMP mappings include:

- Dublin Core title, description, and subjects.
- Photoshop/XMP creation dates and rating.
- EXIF GPS coordinates.
- IPTC `PersonInImage`.
- Metadata Working Group normalized face regions.
- A PhotoDeFrigifier namespace for source IDs, state assertions, resolution
  decisions, and fields that have no portable standard.

The JSONL manifest remains the lossless source of truth when XMP consumers drop
or reinterpret provider-specific values.

## Migration Strategy

### Inventory First

- Scan providers without copying media into application support.
- Store external directory access through user-selected paths/bookmarks.
- Calculate required staging space before extracting or downloading anything.
- Produce count, resource, metadata, and conflict reports before writes.

### Apple Import

- Use `PHAssetCreationRequest` and original resource files.
- Set supported creation date, location, favorite, and privacy state.
- Recreate albums and compound asset resources where PhotoKit supports them.
- Preserve unavailable captions/keywords/people in sidecars and manifests.
- Re-scan imported assets and compare counts/resources before completion.

### Google Backup

- Compare against hashes from the initial Takeout inventory.
- Initially create a Google-ready export for manual upload.
- If OAuth is added later, upload only new canonical media and track every
  app-created Google media ID.
- Use annotated transport copies only when cloud date/location requires embedded
  metadata absent from the original. Never modify the source original.

## Destination Routing

### Apple

- `Visible` plans an ordinary Apple Photos item.
- `Hidden` plans `isHidden` through public PhotoKit and clearly discloses that the
  item remains in iCloud and is not independently encrypted by PhotoDeFrigifier.
- `Exclude` keeps the item out of Apple operations.

### Google

- `Include` places the item in the Google-ready export plan.
- `Exclude` keeps the item out of Google operations.

### Shared Rules

- Most restrictive person routing wins when several people are assigned.
- Items without person assignments default to Apple `Visible` and Google `Include`.
- Every retained original remains in both archive plans regardless of cloud route.
- Do not persist plaintext thumbnails.
- Keep sensitive catalog information encrypted at rest.
- Use an established backend such as `restic`; do not invent an archive format.
- Store secrets in macOS Keychain.
- Require two independent repositories before reporting the asset as protected.
- Run repository integrity checks and restore representative files by SHA-256.

## Disk and Staging Rules

- Internal free space was approximately 25 GiB when planning began.
- Full provider exports and migration staging must use an external disk.
- An encrypted APFS external volume is preferred because exports are plaintext
  personal data before they enter a never-cloud repository.
- The application computes operation-specific space needs and safety headroom.
- A low-space preflight blocks downloads/import copies rather than failing late.
- Temporary staging is removed only after the destination is re-scanned and an
  operation receipt is complete.

## Provider Access Lab

`ProviderAccessLab` is a separate native macOS application target in this
repository. It validates access mechanisms and response shapes without coupling
experimental behavior to the production app.

### Shared Probe Contract

- Provider and access mechanism.
- Probe operation and timestamp.
- Success, failure, or blocked status.
- HTTP status and latency when applicable.
- Sanitized response field paths and aggregate counts.
- Human-readable notes that contain no account or media identifiers.

### Apple Lab Work

- Request and display PhotoKit authorization.
- Compare normal and hidden-inclusive inventory counts.
- Aggregate media/resource roles without exposing filenames or identifiers.
- Later, optionally create a controlled lab-owned asset and test only supported
  metadata writes on that asset.

### Google Lab Work

- Open Takeout and Google-to-iCloud transfer in the system browser.
- Inspect an expanded Takeout directory selected by the user.
- Report media/JSON/album counts and JSON field shapes.
- Do not reuse Google browser cookies or call private Google web APIs.

### Amazon Lab Work

- Accept temporary cookies through a local masked field and retain only Amazon
  authentication/session cookie names needed to reproduce the browser request.
- Send only allowlisted GET requests over normal TLS validation.
- Probe root, usage, one-item search, and the broad available aggregation shape.
- Retain only sanitized response shapes and counts.
- Never persist cookies or include response values in logs/reports.

### Promotion Gate

Lab code moves into the production solution only when:

1. The behavior succeeds repeatedly.
2. Sanitized fixtures capture the response shape.
3. Authentication expiration and failure are understood.
4. Logs and reports are demonstrably secret-free.
5. Parsing and failure behavior have automated tests.
6. This document records the observed capability and risks.
7. Experimental behavior remains optional and clearly labeled.

### Amazon Follow-up Probes

1. Inventory videos and determine how they relate to the photo-only export.
2. Compare `people`, `allPeople`, and `clusterId` entry counts and determine the
   semantics of `match`, `searchData`, and `clusterName` using non-sensitive data.
3. Identify album/visual-collection inventory and membership without mutation.
4. Determine how favorite, hidden, protected-folder, and restricted states map to
   individual media nodes.
5. Download one explicitly selected non-sensitive item and verify Amazon MD5 and
   content-signature behavior against locally calculated hashes.
6. Determine whether unnamed People clusters and per-photo `things` mappings can
   be exported without relying on ambiguous global facets.

## Initial Implementation Phases

1. Living plan document, Makefile, Swift package, app targets, and tests.
2. Shared sanitized probe/report infrastructure.
3. Apple read-only PhotoKit probe.
4. Google browser handoffs and Takeout shape inspector.
5. Isolated Amazon cookie parser and read-only metadata probe.
6. Sanitized report export and fixture workflow.
7. Main application Library Project, folder inventory, and catalog foundation.
8. Apple/Google production adapters, matching, conflict review, XMP, and manifests.
9. Apple migration, Google-ready export, and privacy routing.
10. Encrypted never-cloud backend and full recovery verification.

## Verification Gates

- Formatting, unit tests, and debug/release builds pass through the Makefile.
- Both native app bundles have valid property lists and ad-hoc signatures.
- Probe reports contain no secrets or provider object values.
- Amazon requests reject unknown methods, hosts, paths, and oversized responses.
- No write operation exists without an explicit plan and confirmation.
- Imported/copied bytes are verified by SHA-256 where the provider permits it.
- Every provider import has representative sanitized fixtures before production
  use.
- Never-cloud completion requires a successful test restore.

## Current Environment

- Workspace began empty and was initialized as a Git repository on `main`.
- Xcode 26.6, Swift 6.3.3, GNU Make 3.81, and swift-format 6.3 are available.
- `xcodegen`, `restic`, `exiftool`, and `osxphotos` were not installed at the
  beginning of implementation.
- The first milestone intentionally has no third-party runtime dependencies.

## Primary Sources

- Apple PhotoKit: <https://developer.apple.com/documentation/photokit>
- `PHAssetCreationRequest`: <https://developer.apple.com/documentation/photos/phassetcreationrequest>
- Apple Hidden album: <https://support.apple.com/en-us/104987>
- Google Photos authorization: <https://developers.google.com/photos/overview/authorization>
- Google Photos API changes: <https://developers.google.com/photos/support/updates>
- Google Takeout: <https://support.google.com/accounts/answer/3024190>
- Google transfer to other services: <https://support.google.com/accounts/answer/9666875>
- Google-to-iCloud transfer: <https://support.apple.com/en-us/120924>
- Login with Amazon authorization: <https://developer.amazon.com/docs/login-with-amazon/authorization-code-grant.html>
- Login with Amazon profile scopes: <https://developer.amazon.com/docs/login-with-amazon/customer-profile.html>
- Experimental Amazon client: <https://github.com/trevorhobenshield/amazon_photos>
- Optional Apple database reader: <https://github.com/RhetTbull/osxphotos>
- Restic design: <https://restic.readthedocs.io/en/stable/100_references.html>

## Open Inputs

- External disk path, format, free capacity, and encryption status.
- Representative sanitized Google Takeout and Apple catalog-adapter samples.
- Public project license and final reverse-DNS bundle identifiers.
- Whether automated Google uploads eventually justify registered OAuth.
