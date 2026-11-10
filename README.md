# pascal-search-faa

A search-engine contract for **Delphi and Lazarus/FPC** from one codebase: a declared schema,
documents with string ids, batched upsert and delete, typed filters (never filter text), text
search with sort, paging and facets, and waiting until a write is searchable. Adapters per
engine (Meilisearch first, Typesense to validate the contract) and an in-memory mock for tests.

**Status: 0.1.0, unreleased.** The core, the mock and both adapters (Meilisearch, Typesense)
are done; the same contract suite passes on the mock and on both engines. Versions stay 0.x
until the first release.

Part of the `*-faa` family (MIT, Delphi 12 and FPC 3.2.2, `{$MODE DELPHI}`). Not an adapter of
pascal-db-faa: a search engine is HTTP + JSON with asynchronous writes. A database's own
full-text search is pascal-db-faa's `PascalDb.FullText`.

## Example

```pascal
uses
  PascalSearch.Schema, PascalSearch.Documents, PascalSearch.Filters,
  PascalSearch.Interfaces, PascalSearch.Mock;

var
  Engine: ISearchEngine;
  Products: ISearchIndex;
  R: ISearchResult;
  I: Integer;
begin
  Engine := TMockSearchEngine.New;   // in tests; see "Meilisearch" below
  Products := Engine.EnsureIndex(TSearchSchema.New('products')
    .Text('title').Text('body')
    .Keyword('category', [sfFilter, sfFacet])
    .Num('price', [sfFilter, sfSort]));

  Products.Upsert([
    TSearchDocument.New('1').Str('title', 'Café com leite').Str('category', 'bebida').Num('price', 7.5),
    TSearchDocument.New('3').Str('title', 'Café preto').Str('category', 'bebida').Num('price', 5)
  ]).WaitFor;   // Meilisearch applies writes later: wait before searching

  R := Products.Search('cafe')                       // accents and case folded
    .Where(F.All([F.Eq('category', 'bebida'), F.Le('price', 6)]))
    .OrderBy('price')
    .Page(1, 20)
    .Facets(['category'])
    .Execute;
  for I := 0 to R.Count - 1 do
    Writeln(R.Hit(I).Id, ' ', R.Hit(I).Document.Find('title').AsString);
end.
```

## Meilisearch

```pascal
uses PascalSearch.Meilisearch;

var
  Config: TMeilisearchConfig;
begin
  Config := TMeilisearchConfig.Create('https://search.internal:7700', ApiKey);
  Config.Http.Tls.CaFile := 'ca.pem';   // a private CA; left empty: the system store
  Engine := TMeilisearchEngine.New(Config);   // one per server, shared between threads
```

- TLS is verified on both compilers (chain and host name), through pascal-common-faa's HTTP
  client. `Config.Http` is its `TPcHttpOptions`: a client certificate (mTLS), the pool's
  limits. `Http.Tls.SkipServerVerification` turns verification off: **insecure**, a lab only.
- Writes are asynchronous on Meilisearch: call `WaitFor` before searching what you wrote. A
  write whose request got no answer raises `ESearchUnavailable` and is not repeated; Upsert and
  Delete are idempotent, so send them again.
- `(Engine as IMeilisearchEngine).Send(Method, Path, Body)` reaches any endpoint (synonyms,
  typo tolerance...) with the key and the error mapping; `WaitForTask` waits for its tasks.
- Linux: the package `libssl3` (Debian 12; no `libssl-dev` needed), and `ca-certificates` for a
  server with a public certificate.

## Typesense

```pascal
uses PascalSearch.Typesense;

  Config := TTypesenseConfig.Create('https://search.internal:8108', ApiKey);
  Config.Http.Tls.CaFile := 'ca.pem';
  Engine := TTypesenseEngine.New(Config);
```

- The same TLS options as above. Writes are applied before the answer: `WaitFor` returns at
  once, raising the documents an import refused (the others are kept).
- `EnsureIndex` keeps the schema in the collection's metadata; the adapter checks filter, sort
  and facet fields against it, and searches the `Text` fields.
- A filter value can't hold a backtick on Typesense (nothing escapes it): such a value raises
  `ESearchArgumentError`. At most 3 sort keys.
- `(Engine as ITypesenseEngine).Send(Method, Path, Body)` reaches any endpoint (synonym sets,
  curation...).

## Contents

| Unit | What |
|---|---|
| `PascalSearch.Interfaces` | the contract: engine, index, write, query, result |
| `PascalSearch.Schema` | declared fields and their flags |
| `PascalSearch.Documents` | documents (builder, JSON, DTO) |
| `PascalSearch.Filters` | typed filters (`F.Eq`, `F.AnyOf`, `F.Between`, `F.All`...) |
| `PascalSearch.Values` | instants as Unix ms, numbers in plain decimal |
| `PascalSearch.Errors` | exceptions and the id/name checks |
| `PascalSearch.Query` | query builder and results, shared by adapters |
| `PascalSearch.Mock` | the contract in memory, with test controls |
| `PascalSearch.Version` | `PASCALSEARCH_VERSION` |
| `PascalSearch.EngineJson` | JSON helpers the adapters share |
| `PascalSearch.Meilisearch` | the Meilisearch adapter (`adapters/meilisearch`, own package) |
| `PascalSearch.Typesense` | the Typesense adapter (`adapters/typesense`, own package) |

Docs: [`design.md`](docs/design.md) (decisions S1-S24; sections 8-10 what the
implementation settled), [`engine-findings.md`](docs/engine-findings.md)
(what Meilisearch 1.56.2 and Typesense 30.2 did when probed), [`gotchas.md`](docs/gotchas.md).

## Dependencies

[pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) 1.20.0+ (1.31.0+ with an
adapter) and [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa)
0.7.0+, each as the application's own submodule. Delphi: add `src/` of this library and of both
to the search path, plus `adapters/meilisearch` or `adapters/typesense` for an engine. Lazarus:
`packages/pascal_search_faa.lpk`, plus `pascal_search_faa_meilisearch.lpk` or
`pascal_search_faa_typesense.lpk`.

## Tests

- Unit suite (no engine): FPC on Linux (Docker) `sh tools/test_fpc_docker.sh`, FPC on Windows
  (lazbuild) `sh tools/test_fpc.sh`, Delphi `tests/Unit/PascalSearch.UnitTests.dproj`.
- Integration suite (the contract on Meilisearch and on Typesense, TLS included):
  `sh tools/engines.sh` starts the engines in Docker (`down` removes them); then
  `sh tools/test_fpc.sh integration`, or Delphi `tests/Integration/PascalSearch.IntegrationSuite.dproj`
  run once per engine (`SEARCH_CONTRACT_ENGINE=meilisearch` or `typesense`). On Linux,
  `sh tools/test_integration_docker.sh` does it all.
- Everything CI runs: `sh tools/ci-test.sh`.

Criterion on both: every test green and 0 leaks.

## License

MIT
