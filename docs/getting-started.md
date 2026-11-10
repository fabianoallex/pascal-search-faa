# 1. Getting started

## Choosing an engine

The contract is the same on both; pick by what you run and what you need beyond it.

| | Meilisearch (v1.56.2 probed) | Typesense (30.2 probed) |
|---|---|---|
| Writes | asynchronous: a task, searchable after `WaitFor` | applied before the answer: `WaitFor` returns at once |
| A refused document | the whole batch fails | only that document; the others are kept |
| String equality in a filter | folds case | folds case, accents and some symbols |
| Facet statistics, `EXISTS`, `IS NULL` | yes (native access) | no |
| Schema | the library sets searchable, filterable and sortable attributes | the library keeps its schema in the collection's metadata |

In tests, use the mock (guide 6): the same contract in memory, no server.

## Adding the library

Each `*-faa` library is the application's own git submodule (one copy per application):

- [pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) 1.20.0 or later for
  the core, **1.31.0 or later** with an adapter (its HTTP client);
- [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa) 0.7.0 or later;
- [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa) 0.18.0 or later, only for the
  outbox bridge (guide 7).

**Delphi**: add to the search path `src/` of this library and of pascal-common-faa and
pascal-jsonmapper-faa, plus `adapters/meilisearch` or `adapters/typesense` (and
`bridges/outbox` with pascal-db-faa's `src/` for the bridge).

**Lazarus**: the packages in `packages/`: `pascal_search_faa.lpk`, plus
`pascal_search_faa_meilisearch.lpk`, `pascal_search_faa_typesense.lpk` or
`pascal_search_faa_outbox.lpk`. List `pascal_common_faa` first in the project, with
`DefaultFilename` pointing at your submodule and `Prefer="True"`: without it lazbuild may build
against another copy registered in the IDE.

An adapter checks pascal-common-faa's version at compile time: an older copy stops the build
with "pascal-search-faa needs pascal-common-faa 1.31.0 or later". Your own code can check this
library's version the same way (`PASCALSEARCH_VERSION` in `PascalSearch.Version`).

Every FPC program calls `SetMultiByteConversionCodePage(CP_UTF8)` at startup and, on Unix,
lists `cthreads` and `cwstring` first in its `uses`.

## Meilisearch

```pascal
uses PascalSearch.Interfaces, PascalSearch.Meilisearch;

var
  Config: TMeilisearchConfig;
  Engine: ISearchEngine;
begin
  Config := TMeilisearchConfig.Create('https://search.internal:7700', ApiKey);
  Config.Http.Tls.CaFile := 'ca.pem';   // a private CA; left empty: the system store
  Config.WaitTimeoutMs := 30000;        // WaitFor(0)'s limit (the default)
  Engine := TMeilisearchEngine.New(Config);
```

## Typesense

```pascal
uses PascalSearch.Interfaces, PascalSearch.Typesense;

  Config := TTypesenseConfig.Create('https://search.internal:8108', ApiKey);
  Config.Http.Tls.CaFile := 'ca.pem';
  Engine := TTypesenseEngine.New(Config);
```

## Configuration, TLS and threads

- `TimeoutMs` is each request's limit per wait (connect, read, write); 0 is the transport's
  default, 15 s.
- `Http` is pascal-common-faa's `TPcHttpOptions`: `Http.Tls.CaFile` for a private CA (PEM),
  `CertFile`/`KeyFile`/`CertPassword` for a client certificate (mTLS), the connection pool's
  limits. TLS is verified on both compilers, the chain and the host name.
  `Http.Tls.SkipServerVerification` turns that off: **insecure**, for a lab only.
- The library reads no environment variables: fill the record from your configuration.
- **One engine per server, shared between threads.** It owns one HTTP transport and its pool
  of kept-alive connections; each call is its own exchange.
- Linux: the package `libssl3` (Debian 12; no `libssl-dev`), and `ca-certificates` for a
  server with a public certificate.
