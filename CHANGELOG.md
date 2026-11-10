# Changelog

All notable changes to this project. Versions follow `MAJOR.MINOR.PATCH`; until 1.0.0 the
contract may change in a minor version (it is validated against two engines first).

## [Unreleased] - 0.1.0

### Added

- The contract (`PascalSearch.Interfaces`): `ISearchEngine`, `ISearchIndex`, `ISearchWrite`
  (`WaitFor`), `ISearchQuery`, `ISearchResult`, `ISearchHit(s)`. Design and decisions:
  `docs/design.md`; what the engines did when probed: `docs/engine-findings.md`.
- `PascalSearch.Schema`: declared fields (`Text`, `Keyword`, `Keywords`, `Num`, `Int`, `Bool`,
  `Instant`, `Stored`) with filter, sort and facet flags, and `MaxHits`.
- `PascalSearch.Documents`: documents built field by field, from JSON or from a DTO
  (pascal-jsonmapper-faa), with the id checked at once.
- `PascalSearch.Filters`: typed filters (`Eq`, `NotEq`, `AnyOf`, `NoneOf`, `Gt`, `Ge`, `Lt`,
  `Le`, `Between`, `All`, `Any`), never text.
- `PascalSearch.Values`: instants as Unix milliseconds, numbers in plain decimal.
- `PascalSearch.Errors`: the exception classes and the id, index name and field name checks.
- `PascalSearch.Query`: the query builder and result classes the adapters share.
- `PascalSearch.Mock`: the contract in memory, with `DeferWrites`, `FailNextWrite` and
  `Unavailable` for tests.
- `PascalSearch.Meilisearch` (package `pascal_search_faa_meilisearch`, Meilisearch v1.56.2):
  the contract over pascal-common-faa 1.31.0's HTTP client, TLS verified on both compilers
  (`TMeilisearchConfig.Http`: a private CA, mTLS). Writes wait on tasks (`WaitFor` polls with
  `TSleep`); a refused batch raises `ESearchWriteFailed` with every id; a write without an answer
  raises `ESearchUnavailable` and is not repeated. Native access: `IMeilisearchEngine.Send`,
  `WaitForTask`. `MeilisearchFilterText` writes filters with every string quoted and escaped.
- `PascalSearch.Typesense` (package `pascal_search_faa_typesense`, Typesense 30.2): the
  contract over the same HTTP client and TLS options. The library's schema is kept in the
  collection's metadata, so filter, sort and facet fields are checked as on the other engines
  and the Text fields searched; `EnsureIndex` changes a collection in place with one PATCH.
  Imports report refused documents through `WaitFor`, the others kept. `TypesenseFilterText`
  writes every string in backticks and refuses one holding a backtick. Native access:
  `ITypesenseEngine.Send`.
- `PascalSearch.EngineJson`: JSON helpers both adapters use (in the core package).
- Unit suite: 135 tests (core, the contract suite on the mock, the mock's own, both adapters on
  a fake transport). Integration suite: 63 tests, run once with the contract suite on
  Meilisearch and once on Typesense (`SEARCH_CONTRACT_ENGINE`), with both adapters' own tests;
  engines in Docker, http and https with a private CA (`tools/engines.sh`). DUnitX masters and
  generated FPCUnit mirrors.
