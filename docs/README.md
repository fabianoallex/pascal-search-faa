# Documentation

Guides for using pascal-search-faa, in the order the concepts build on each other. The code
compiles unchanged on Delphi 12 and Free Pascal 3.2.2; the sample does too.

| Guide | What it covers | Sample |
|---|---|---|
| [1. Getting started](getting-started.md) | Choosing an engine, adding the library (Delphi search path, Lazarus packages), configuring Meilisearch or Typesense, TLS, one engine per server shared between threads, tracing and metrics | 01 |
| [2. Schema and documents](schema-and-documents.md) | Declaring an index (`Text`, `Keyword`, `Num`... with filter, sort and facet flags), `EnsureIndex` and what it can change in place, documents and their ids, instants and numbers | 01 |
| [3. Writing and waiting](writing.md) | `Upsert`, `Delete`, `DeleteWhere`, `WaitFor`, refused documents, a write that got no answer | 01 |
| [4. Searching](searching.md) | Text, typed filters, sort, paging, facets, the fields returned, highlight, synonyms, `Get`/`GetMany`, the engine's native access and typed settings | 01 |
| [5. Errors](errors.md) | The exception classes, chosen by what the caller does next | — |
| [6. Testing with the mock](testing-with-the-mock.md) | `TMockSearchEngine`: the contract in memory, `DeferWrites`, `FailNextWrite`, `Unavailable`, and what it doesn't do (typos) | — |
| [7. The outbox bridge](outbox.md) | Keeping an index in step with the database through pascal-db-faa's transactional outbox: the handler, the loader, retries, giving up on a caller's bug, a full reindex | 01 |
| [8. What each engine does differently](engine-differences.md) | Meilisearch and Typesense behind the same contract: the differences that still show, and the rules that avoid them | — |
| [9. Rebuilding an index](rebuilding.md) | Filling a new index beside the live one and `ReplaceIndex`; the outbox meanwhile; `ListIds` past `MaxHits` | — |

Sample: [`samples/01-outbox`](../samples/01-outbox/SearchOutbox.dpr), a SQLite database
(pascal-db-faa), its outbox and an index (the mock by default, Meilisearch or Typesense by
setting).

## Status and reference

- Versions and what changed in each: [`CHANGELOG.md`](../CHANGELOG.md). While the version is
  0.x, a minor version may change the API.
- [`design.md`](design.md): the decisions (S1-S36) and what each part's implementation
  settled (sections 8-13). [`engine-findings.md`](engine-findings.md): what Meilisearch 1.56.2
  and Typesense 30.2 did when probed, numbered ("finding N"). [`gotchas.md`](gotchas.md): the
  Delphi × FPC and engine surprises found by measurement.
- [`CLAUDE.md`](../CLAUDE.md) holds the conventions for working on the library itself.
