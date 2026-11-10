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

## Where things stand (2026-11-10)

- **Decisions**: `docs/design.md` (S1-S24, accepted; sections 8 and 9 are what the core and
  the Meilisearch adapter settled). **Engine behavior**: `docs/engine-findings.md`, numbered; the design cites it as
  "finding N". Read both before changing the contract.
- **Done**: core (`src/`) and mock; the Meilisearch adapter (`adapters/meilisearch`, its own
  package) on pascal-common-faa 1.31.0's `PascalCommon.Http`. Unit suite 105/105 and
  integration suite 50/50 (the contract suite plus the adapter's tests, on Meilisearch in
  Docker, http and https with a private CA), 0 leaks, on FPC Linux and Windows. Delphi: the
  user compiles and runs both suites in the IDE.
- **HTTP**: only through `PascalCommon.Http` (pascal-common-faa 1.31.0+): one transport per
  engine, kept alive; tests on `TPcFakeHttpTransport`. Paths and queries encoded with
  `PcPercentEncode`. A POST is never sent twice by the transport, and the adapters don't
  repeat a write either (design, section 9).
- **Next**: `adapters/typesense` (its own package, the same contract suite), then the outbox
  bridge (a separate package depending on pascal-db-faa), sample and guide, then the entry in
  the skill's `faa-libraries.md` once a version is published.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* has accents
on purpose (`'Café'`, `'Água'`).

---

## Code rules (every unit in `src/` and `adapters/`)

- **Each adapter is its own package** (`adapters/<engine>/`, `pascal_search_faa_<engine>.lpk`):
  the core needs pascal-common-faa 1.20.0, an adapter 1.31.0 (`$MESSAGE FATAL` in its unit).

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
- The integration suite (`tests/Integration`) runs the contract suite on Meilisearch
  (`PascalSearch.IntegrationEnv` points `ContractEnv` at it) plus each adapter's own tests (TLS,
  auth, tasks). Engines: `sh tools/engines.sh` (up/down; host ports 17700 http and 17701 https,
  CA in `.ci/it-certs`).
- Exceptions in tests: `try ... TAssert.Fail(...) except on E: EClass do ... end` (the compat
  unit's `AssertException` demands the exact class).
- Runs: `sh tools/test_fpc_docker.sh` (unit, Linux FPC 3.2.2, heaptrc),
  `sh tools/test_integration_docker.sh` (integration, Linux, starts and removes the engines),
  `sh tools/test_fpc.sh [integration]` (lazbuild on Windows; integration needs
  `sh tools/engines.sh` first), `sh tools/ci-test.sh` (what CI runs: both suites). Delphi: the
  user compiles `tests/Unit/PascalSearch.UnitTests.dproj` and
  `tests/Integration/PascalSearch.IntegrationSuite.dproj` in the IDE (Delphi CE has no
  command-line compiler) and runs the `.exe`. Criterion: all green, 0 leaks, on both.
- New `.dproj` go into `PascalSearch.groupproj`, new `.lpi` into `PascalSearch.lpg`.

---

## Engines in Docker

Pinned: `getmeili/meilisearch:v1.56.2`, `typesense/typesense:30.2` (31 was still a release
candidate). Probes go in `.ci/probe-*` (git-ignored); their findings get a numbered record in
`docs/`. Don't restart the user's stopped containers; create your own with their own names and
remove them at the end (`tools/engines.sh` uses `pascalsearch-it-*` and the network
`pascalsearch-it-net`).

Ask before committing or pushing.
