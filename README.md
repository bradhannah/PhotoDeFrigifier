# PhotoDeFrigifier

PhotoDeFrigifier is a local-first macOS project for reconciling Apple Photos,
Google Photos, Amazon Photos, and loose media without modifying source originals.

The repository currently contains a provider-neutral catalog library and two
native macOS executables:

- `PhotoCatalogCore`: versioned canonical entities, import adapters, identity
  indexes, claim-preserving merges, and private JSONL persistence.
- `ApplePhotosAdapter`: a production PhotoKit inventory adapter that reads the
  system library without modifying it or downloading iCloud-only resources.
- `PhotoDeFrigifierApp`: the production Library Project dashboard and staged
  reconciliation workflow.
- `ProviderAccessLab`: an isolated utility for safe provider capability probes.

See [`docs/PLAN_DETAILS.md`](docs/PLAN_DETAILS.md) for decisions, provider
constraints, security rules, and the implementation roadmap.

## Common Commands

```sh
make help
make doctor
make build
make test
make check
make package
make run
make run-lab
```

`make run` packages both applications. Provider Access Lab remains available
from the production app's Advanced section. Use `make run-lab` to open the lab
directly.

The application uses only Apple system frameworks and Swift Package
Manager. It does not require provider developer accounts or third-party tools.

Provider Access Lab can create a complete private Amazon metadata inventory as
JSONL. Unlike sanitized probe reports, that file contains identifying metadata;
write it only to an encrypted or otherwise private destination. Authentication
cookies remain memory-only and are never included in the export. The export
flow first loads a Cookie request header from a selected local file (or the
masked field), then selects a private output directory for a timestamped JSONL
file.

The production app creates or opens a `.photodefrigifier` Library Project. Each
project package contains a private manifest, canonical catalog, and user-authored
review state. It can gather Apple Photos through PhotoKit, completed Amazon
inventories, or ordinary folders on disk. Folder scans recurse without changing
source files, measure SHA-256 and MD5 in one streaming pass, and read embedded
image metadata when available. A folder source can be replaced while preserving
its source identity and scan history.

An Amazon inventory can own several attached download-folder sources. The app
tracks confirmed downloaded items, missing inventory items, candidate local
matches, and unmatched local files without treating provider-reported MD5 as
verified identity.

Apple scans include hidden and burst assets, user and smart album memberships,
and compound resources such as RAW and Live Photo pairs. Locally available
resources are measured without network access; iCloud-only and unreadable
resources are reported separately.

Each provider occurrence begins as a provisional asset. Amazon-reported MD5 plus
byte length can be compared with locally measured MD5 only as an explicit review
candidate. Ambiguous MD5 collisions are withheld, and automatic resource matches
still require locally measured SHA-256, byte length, current observations, and
compatible resource roles. Confirmed review relationships can propagate source
People claims into PhotoDeFrigifier-managed canonical people and privacy
categories without attempting to change Apple Photos People data. Project files
retain raw provider records and identifying metadata, are written atomically with
mode `0600`, and still require encrypted or otherwise private storage.

Matches compares memory-only visual previews side by side. Exact SHA-256 pairs
are automatic and cannot be rejected; Amazon MD5/type, normalized filename, and
matching-stem pairs require explicit review bound to the current observations.
Apple previews are marked as asset renditions because public PhotoKit cannot
promise a resource-specific thumbnail. Local previews are opened beneath their
security-scoped source without following symlinks and are revalidated against the
cataloged SHA-256 before decoding.

People routing is explicit per destination: Apple `Visible`, `Hidden`, or
`Exclude`, and Google `Include` or `Exclude`. The most restrictive assigned
person wins. Destinations persist a Google-ready export location and two distinct
archive locations. Review derives a non-destructive plan and blockers; this
version performs no move, upload, deletion, PhotoKit write, or archive operation.
