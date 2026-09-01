# PhotoDeFrigifier

PhotoDeFrigifier is a local-first macOS project for reconciling Apple Photos,
Google Photos, Amazon Photos, and loose media without modifying source originals.

The repository currently contains a provider-neutral catalog library and two
native macOS executables:

- `PhotoCatalogCore`: versioned canonical entities, import adapters, identity
  indexes, claim-preserving merges, and private JSONL persistence.
- `PhotoDeFrigifierApp`: the production application shell.
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

`make run` packages both applications. The main window can then launch Provider
Access Lab directly. Use `make run-lab` to open the lab without the production
shell.

The initial milestone uses only Apple system frameworks and Swift Package
Manager. It does not require provider developer accounts or third-party tools.

Provider Access Lab can create a complete private Amazon metadata inventory as
JSONL. Unlike sanitized probe reports, that file contains identifying metadata;
write it only to an encrypted or otherwise private destination. Authentication
cookies remain memory-only and are never included in the export. The export
flow first loads a Cookie request header from a selected local file (or the
masked field), then selects a private output directory for a timestamped JSONL
file.

The production app can import a completed Amazon inventory into a new canonical
catalog or merge it into an existing one. Each provider occurrence begins as a
provisional asset. Provider-reported Amazon MD5 values create review candidates
only; automatic resource matches require locally measured SHA-256 plus byte
length and compatible resource roles. Catalog files retain raw provider records
and identifying metadata, are written atomically with mode `0600`, and still
require encrypted or otherwise private storage.
