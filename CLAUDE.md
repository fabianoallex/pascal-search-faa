# pascal-search-faa — Guide for AI agents

A **dual-compiler** (Delphi + Lazarus/FPC) search-engine contract: a declared schema, documents
with string ids, batched writes with `WaitFor`, typed filters, text search with sort, paging and
facets; adapters per engine (Meilisearch, then Typesense) and an in-memory mock.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill; for consuming the other `*-faa` libraries, the
`using-faa-libraries` skill. Both live in
[pascal-skills-faa](https://github.com/fabianoallex/pascal-skills-faa) (a Claude Code plugin);
if they aren't loaded, ask the user to install it: `/plugin marketplace add
fabianoallex/pascal-skills-faa`, then `/plugin install pascal-skills-faa@pascal-skills-faa`.
This file records only what is specific to this repository.

---

## Where things stand (2026-11-11)

- **0.2.0 (2026-11-11)** (design section 12, S25-S31; findings 57-71): `ReplaceIndex`,
  `ListIds`, highlight in parts (`ToHtml` escapes), `SetSynonyms` in the contract, typed native
  settings (Meilisearch typo/ranking/stop words, Typesense curation), `CacheMs`, and the outbox
  bridge giving up at once (`EOutboxGiveUp`, pascal-db-faa **0.21.0**, now in `external/`).
  Unit 201/201, integration 87/87 on each engine, sample unchanged, 0 leaks, FPC Linux and
  Windows; the user built it on Delphi 12.
- **Decisions**: `docs/design.md` (S1-S31, accepted; sections 8-12 are what the core, the
  Meilisearch adapter, the Typesense adapter, the outbox bridge and 0.2.0 settled). **Engine behavior**: `docs/engine-findings.md`, numbered; the design cites it as
  "finding N". Read both before changing the contract. **Guides** for users: `docs/README.md`.
- **Done (0.1.0)**: core (`src/`) and mock; the Meilisearch and Typesense adapters
  (`adapters/meilisearch`, `adapters/typesense`, each its own package) on pascal-common-faa
  1.31.0's `PascalCommon.Http`; the outbox bridge (`bridges/outbox`, its own package, on
  pascal-db-faa 0.20.1 in `external/`, minimum 0.18.0); sample `samples/01-outbox`; the guides.
  Unit suite 156/156; integration suite 66/66 twice (the contract suite on Meilisearch, then on
  Typesense, plus both adapters' tests and the bridge end to end on SQLite; engines in Docker,
  http and https with a private CA), and the sample's output on the mock and both engines, 0
  leaks, on FPC Linux and Windows, and on Delphi 12 Win32 and Win64 (the user compiles both
  suites and the sample in the IDE; the `.exe` can be run from here).
- **HTTP**: only through `PascalCommon.Http` (pascal-common-faa 1.31.0+): one transport per
  engine, kept alive; tests on `TPcFakeHttpTransport`. Paths and queries encoded with
  `PcPercentEncode`. A POST is never sent twice by the transport, and the adapters don't
  repeat a write either (design, section 9).
- **Typesense keeps the library's schema in the collection's metadata** (design, section 10):
  the adapter checks filter/sort/facet fields and builds `query_by` from it. Since 0.2.0 an
  index is an **alias** to the collection `<name>@<Unix ms>` (S25): `ReplaceIndex` moves the
  alias; a 0.1.0 collection (no alias) still works. Synonym and curation sets are named like the
  collection and deleted only after it (finding 68).
- **Highlight never returns the engine's tagged text** (S27): the adapters ask for `#1`/`#2` as
  tags and cut the value into parts; neither engine escapes HTML (finding 64).
- **The outbox bridge is a handler of pascal-db-faa's local sink** (design, section 11): the
  loader decides (an id without a document is deleted), every error is raised for the outbox
  to retry, except `ESearchArgumentError`/`ESearchRequestError`, which `Handle` turns into
  `EOutboxGiveUp` (dead at once, S30); a reindex is the application's loop over `Sync`, best
  into a new index followed by `ReplaceIndex` (guide 9).
- **Released**: `v0.1.0` (2026-11-10), `v0.2.0` (2026-11-11), listed in the skill's `faa-libraries.md` and in
  `using-faa-libraries`' minimum-version matrix. A release that changes a minimum version
  updates that matrix too.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* has accents
on purpose (`'Café'`, `'Água'`).

---

## Code rules (every unit in `src/`, `adapters/` and `bridges/`)

- **Each adapter is its own package** (`adapters/<engine>/`, `pascal_search_faa_<engine>.lpk`):
  the core needs pascal-common-faa 1.20.0, an adapter 1.31.0 (`$MESSAGE FATAL` in its unit).
  The outbox bridge too (`bridges/outbox/`, `pascal_search_faa_outbox.lpk`): only it depends on
  pascal-db-faa (0.21.0 since 0.2.0, checked in the unit); the core never does.

- **Every `.pas` is UTF-8 with a BOM** (a file written by a tool has none: add it). Delphi reads
  a file without one as ANSI and garbles accented literals (gotcha 9).
- **`{$I pascalsearch.inc}` right after `unit ...;`**: `{$MODE DELPHI}{$H+}` on FPC,
  `PASCALSEARCH_WINDOWS`, `PASCALSEARCH_FUNCREFS`.
- **`uses` without namespaces** (`SysUtils`, never `System.SysUtils`).
- **No anonymous methods.** Public callbacks follow `PASCALSEARCH_FUNCREFS`: `reference to` on
  Delphi, `of object` on FPC (pascal-db-faa's `PASCALDB_FUNCREFS` rule).
- **Atomics and monotonic time only through `PascalCommon.Threading`**; replaceable sleep and
  clocks through `PascalCommon.SystemContext` (the Meilisearch adapter's task polling uses
  `TSleep`, so unit tests never sleep).
- **The `PascalSearch.*` prefix is mandatory**, also for the adapters
  (`PascalSearch.Meilisearch`, `PascalSearch.Typesense`).
- **Top-of-file comment in every unit, program and test** (plain prose, no banners). If it
  quotes a `}` (JSON, a directive), use `(* ... *)`: gotcha 4.
- **Filters are a tree, never text.** An adapter writes its engine's syntax from
  `ISearchFilter` and quotes every value as measured (design S13, gotcha 3). Never add an API
  that takes filter text from the caller; engine-specific needs go through the adapter's
  native access (S20).
- **Ids, index names and field names are checked at the call** (`PascalSearch.Errors`), on the
  common ground of both engines (findings 9-11).
- Numbers in a filter go through `SearchNumberText` (gotcha 2); instants are Unix milliseconds
  (`SearchInstantToMs`).
- Facet values are ordered by `TSearchResult.AddFacet`; adapters don't sort them themselves.

---

## Tests

- DUnitX masters in `tests/Unit/*Tests.pas` and `tests/Integration/*Tests.pas`, in FPCUnit's
  assertion dialect (through `PascalSearch.DUnitXCompat`); the FPCUnit mirrors in `*/fpc` are
  **generated** by
  `python tools/gen_fpc_mirror.py`: never edit them. `tools/gen_fpc_mirror.py` and the compat
  unit are the skill's canonical test kit, unchanged (`check_test_kit.py` in the skill).
- `PascalSearch.ContractTests` is the contract every engine keeps; it runs on the engine
  `PascalSearch.ContractEnv` gives (the mock by default). Only behavior both engines showed in
  the probe belongs there; what one engine does differently goes to that adapter's tests or to
  `PascalSearch.MockTests`. Engines have typo tolerance: a test expecting a word not to match
  picks one no text field comes close to (gotcha 6).
- The integration suite (`tests/Integration`) runs the contract suite on the engine
  `SEARCH_CONTRACT_ENGINE` names (`meilisearch`, the default, or `typesense`;
  `PascalSearch.IntegrationEnv` points `ContractEnv` at it) plus both adapters' own tests (TLS,
  auth, tasks, metadata); the scripts run it once per engine. Engines: `sh tools/engines.sh`
  (up/down; Meilisearch on host ports 17700/17701, Typesense on 18108/18109, http/https; CA in
  `.ci/it-certs`).
- Exceptions in tests: `try ... TAssert.Fail(...) except on E: EClass do ... end` (the compat
  unit's `AssertException` demands the exact class).
- Runs: `sh tools/test_fpc_docker.sh` (unit, Linux FPC 3.2.2, heaptrc),
  `sh tools/test_integration_docker.sh` (integration, Linux, starts and removes the engines),
  `sh tools/test_fpc.sh [integration]` (lazbuild on Windows; integration needs
  `sh tools/engines.sh` first), `sh tools/ci-test.sh` (what CI runs: both suites). Delphi: the
  user compiles `tests/Unit/PascalSearch.UnitTests.dproj` and
  `tests/Integration/PascalSearch.IntegrationSuite.dproj` in the IDE (Delphi CE has no
  command-line compiler) and runs the `.exe`. Criterion: all green, 0 leaks, on both.
- The outbox bridge's integration tests and sample 01 use a SQLite file next to the program.
  FireDAC links SQLite in; SQLdb on Windows needs a 64-bit sqlite.org DLL:
  `SEARCH_SQLITE_CLIENT` (tests) / `SEARCH_SAMPLE_SQLITE_CLIENT` (sample), e.g. pascal-db-faa's
  `.deps/sqlite-3.53.4/x64/sqlite3.dll` in the sibling checkout. The Linux scripts install
  `libsqlite3-0`; `test_integration_docker.sh` also checks the sample's output against
  `samples/01-outbox/expected.txt` on the mock and both engines.
- New `.dproj` go into `PascalSearch.groupproj`, new `.lpi` into `PascalSearch.lpg`.

---

## Engines in Docker

Pinned: `getmeili/meilisearch:v1.56.2`, `typesense/typesense:30.2` (31 was still a release
candidate). Probes go in `.ci/probe-*` (git-ignored); their findings get a numbered record in
`docs/`. Don't restart the user's stopped containers; create your own with their own names and
remove them at the end (`tools/engines.sh` uses `pascalsearch-it-*` and the network
`pascalsearch-it-net`).

Ask before committing or pushing.
