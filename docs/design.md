# pascal-search-faa: contract design (2026-11-09)

Status: **accepted 2026-11-09, as proposed** (the open questions of section 7 closed with the
proposed defaults: milliseconds, words-only text, every word required, the common id set only).
Core and mock implemented the same day (section 8 lists what the implementation settled). The
Meilisearch adapter followed on 2026-11-10, on pascal-common-faa 1.31.0's HTTP client (section 9).
Every decision is numbered (S1...).
"Finding N" points to [`engine-findings.md`](engine-findings.md) (Meilisearch 1.56.2 and
Typesense 30.2, measured through FPC 3.2.2 on Linux).

## 1. Scope

A contract for external search engines, one adapter per engine, and an in-memory mock:

- **In the contract**: an index with a declared schema; documents with a string id; upsert and
  delete in batches; delete by filter; get by ids; search with text, a typed filter, sort,
  paging, facets and the fields to return; waiting until a write is searchable.
- **Out of it, through the adapter's native access**: synonyms, typo settings, ranking rules,
  stop words, highlight, scores, `EXISTS`/`IS NULL`, negated groups, prefix filters, geo,
  vectors, keys management.
- **Not here**: the database's own full-text search (pascal-db-faa's `PascalDb.FullText`).

## 2. Packages and dependencies

| Package | Units | Depends on |
|---|---|---|
| `pascal_search_faa` (core, `src/`) | `PascalSearch.Version`, `.Interfaces`, `.Schema`, `.Documents`, `.Filters`, `.Errors`, `.Values`, `.Query`, `.Mock` | pascal-common-faa 1.20.0+ (`PcFoldForSearch`, `PcLowerCase`), pascal-jsonmapper-faa 0.7.0+ (JSON DOM, DTO mapping) |
| `pascal_search_faa_meilisearch` (`adapters/meilisearch/`) | `PascalSearch.Meilisearch` | core, pascal-common-faa 1.31.0+ (`PascalCommon.Http`, `TSleep`/`TTicker`) |
| `pascal_search_faa_typesense` | `PascalSearch.Typesense` | core |
| `pascal_search_faa_outbox` (later, step 7) | `PascalSearch.Outbox` | core, pascal-db-faa |

**S1. JSON through pascal-jsonmapper-faa.** Its DOM (`TJsonValue`) gives the same text on both
compilers, keeps number text (an Int64 id survives) and always writes `.` as decimal separator
(finding 24 needs that). A document can be built field by field, taken from a DTO through
`TJsonMapper`, or from JSON text.

**S2. HTTP through pascal-common-faa** (the decision taken after the probe): the transport's
interface and fake move there from pascal-api-infra-faa; on FPC it runs on
`PascalCommon.Transport.Tls`, which verifies the certificate and the host name (findings 40-42).
Until that version exists, the core and the mock can be written and tested; the adapters wait.
The work on pascal-common-faa is its own plan, agreed separately. **Done:** pascal-common-faa
1.31.0 (`PascalCommon.Http`, `.Http.Client`, `.Http.Fake`; its `docs/http-design.md`, H1-H11), the
same client on Delphi and FPC. Findings 40-42 no longer hold on it (measured, see
`engine-findings.md`).

## 3. The contract

### 3.1 Engine and index

```pascal
ISearchEngine = interface
  /// Creates the index, or brings an existing one up to ASchema (adds fields, changes flags).
  /// A change the engine can't make in place (a field's type) raises ESearchSchemaError: the
  /// application drops and rebuilds the index.
  function EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
  function Index(const AName: string): ISearchIndex;   // no request
  function IndexExists(const AName: string): Boolean;
  procedure DropIndex(const AName: string);            // a missing index is not an error
end;

ISearchIndex = interface
  function Name: string;
  function Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
  function Delete(const AIds: array of string): ISearchWrite;
  function DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
  function Get(const AId: string): ISearchHit;                        // nil when missing
  function GetMany(const AIds: array of string): ISearchHits;        // missing ids left out
  function Search(const AText: string): ISearchQuery;
end;
```

**S3. A schema is declared, for both engines.** Typesense needs one before the first document;
Meilisearch filters, sorts and facets only on declared attributes (findings 8, 20, 32, 35), and
searches every attribute unless told otherwise (finding 18). One declaration gives both the same
behavior:

```pascal
Schema := TSearchSchema.New('products')
  .Text('title').Text('body')                 // searched by the text, in this order
  .Keyword('category', [sfFilter, sfFacet])   // string, compared whole
  .Keywords('tags', [sfFilter, sfFacet])      // array of strings
  .Num('price', [sfFilter, sfSort])           // Double
  .Int('stock', [sfFilter, sfSort])           // Int64
  .Bool('available', [sfFilter])
  .Instant('created_at', [sfFilter, sfSort])  // see S9
  .Stored('image_url');                       // returned, never searched or filtered
```

Every field is optional (a document may omit it), except the id. Meilisearch gets
`searchableAttributes` (the `Text` fields, in order), `filterableAttributes` (filter or facet),
`sortableAttributes`; Typesense gets fields with `index`, `facet`, `sort`, `optional: true`, and
`index: false` for `Stored`.

**S4. The index name** is the common ground: `[A-Za-z0-9_-]`, 1-64 characters (Meilisearch's
rule; Typesense accepted `a b`, finding 8). Checked at the call.

### 3.2 Documents and ids

```pascal
Doc := TSearchDocument.New('42')
  .Str('title', 'Café com leite')
  .Strs('tags', ['quente', 'café'])
  .Num('price', 7.5).Int('stock', 3).Bool('available', True)
  .Instant('created_at', LUtc)
  .Null('category');                      // or simply don't set it
Doc := TSearchDocument.FromObject('42', LProductDto);   // TJsonMapper, published properties
Doc := TSearchDocument.FromJson('{"id":"42",...}');
```

**S5. An id is a string of `[A-Za-z0-9_-]`, 1-511 bytes**, checked at the call
(`ESearchArgumentError`). It is what both engines accept (findings 9-11); Meilisearch would only
report a bad id inside the task, after the call returned. A database integer id becomes its
decimal text. The library always sends the id as a JSON string (Meilisearch treats `123` and
`"123"` as one document anyway; Typesense refuses a number).

### 3.3 Writes and waiting

```pascal
ISearchWrite = interface
  /// Returns once the write is searchable; raises ESearchWriteFailed when the engine refused
  /// it (Failures lists the documents), ESearchTimeout when it still runs after ATimeoutMs.
  procedure WaitFor(ATimeoutMs: Integer = 0);   // 0: the engine's configured default
  function Pending: Boolean;                     // asks the engine (Meilisearch); False on Typesense
end;
```

**S6. Every write returns an `ISearchWrite`; waiting is explicit.** Meilisearch writes are
asynchronous and report their errors only in the task (findings 1-3); Typesense answers after
indexing (finding 4), so its `WaitFor` returns at once. A caller that doesn't wait doesn't learn
about a refused document on Meilisearch: the docs say so, and the outbox bridge always waits.
Meilisearch's wait polls `GET /tasks/{uid}`, starting at 5 ms and doubling up to 200 ms, through
pascal-common-faa's replaceable `TSleep` (no real sleep in unit tests).

**S7. Failures are per document, with a flag for "the whole batch".**
`ESearchWriteFailed.Failures: TArray<TSearchFailure>` (`Id`, `Code`, `Message`). Typesense keeps
the good documents of an import and lists the bad ones (finding 5); a Meilisearch task is all or
nothing (finding 2), so every id of the batch is listed and `WholeBatch` is `True`. An outbox
handler retries the whole batch on `WholeBatch`, only the failed ids otherwise.

**S8. Upsert replaces the document; delete is idempotent.** Upsert maps to Meilisearch
`POST /documents` and Typesense `import?action=upsert` (finding 6). Deleting a missing id is not an
error on any adapter: Typesense's single delete answers 404 for it (finding 7), so the adapter
deletes by `filter_by=id:[...]`. Partial update (merge) stays out of the contract for now: the
engines disagree on a missing document (Meilisearch creates a partial one, Typesense 404 on
`update`, `emplace` needs every required field) and the outbox use case sends whole documents.

### 3.4 Values

**S9. Dates are instants stored as Unix milliseconds (Int64), UTC.** Neither engine compares date
text, and Meilisearch answers 0 hits silently to a date string (finding 26). `Instant` in the
schema, the document and the filters takes a `TDateTime` that is UTC; the library converts.
(Seconds would also do; milliseconds keep `TDateTime`'s precision and fit a Double exactly.)

**S10. Numbers are written in plain decimal with `.`, never with an exponent**: Meilisearch
answers 0 hits to `1e1` and Typesense matches nothing (finding 24). NaN and infinity are refused
at the call.

### 3.5 Filters

**S11. Filters are a typed tree, never a string.** Built with `TSearchFilters` (alias `F`), and
each adapter writes the engine's syntax:

```pascal
F.All([
  F.Eq('category', 'bebida'),
  F.Between('price', 5, 8),            // inclusive
  F.Any([F.Eq('available', True), F.Gt('stock', 0)]),
  F.NoneOf('tags', ['gelada']),
  F.Ge('created_at', LSinceUtc)
])
```

Comparisons: `Eq`, `NotEq`, `AnyOf` (in), `NoneOf` (not in), `Gt`, `Ge`, `Lt`, `Le`, `Between`;
combinators `All` (and), `Any` (or). Values: string, Int64, Double, Boolean, instant. On an array
field, `Eq`/`AnyOf` match a document whose array holds the value (both engines, finding 29).

**S12. What is left out on purpose**: negating a group or a range (Typesense 30.2 has no `!(...)`,
and `NOT price > 5` keeps documents without a price on Meilisearch while `price <= 5` drops them
on both, finding 28); `Exists`/`IsNull`/`IsEmpty` (Meilisearch only, finding 27); prefix and
contains (finding 30). `NotEq` and `NoneOf` keep documents without the field, on both engines and
in the mock. The rest goes through the native access (S20).

**S13. The adapters' escaping, as measured.**
- Meilisearch: every string value in double quotes with `\` and `"` escaped (finding 21).
- Typesense: every string value in backticks; a value containing a backtick is refused
  (`ESearchArgumentError`), because nothing escapes it (`` \` ``, a doubled backtick and `\"`
  inside double quotes all let a filter through, finding 22); `AnyOf`/`NoneOf` are written as
  `||`/`&&` of single comparisons, never as `[...]`, where a backslash changes the parse.
- Field names: `[A-Za-z_][A-Za-z0-9_]*`, checked when the filter is built (a field name is
  written unquoted on both engines). A field not declared filterable in the schema is refused by
  the mock and by Meilisearch (400); the adapters don't check the schema themselves, the engine
  answers.

**S14. String equality is "case-insensitive; accents depend on the engine".** Meilisearch `=`
folds case only; Typesense `:=` folds case, accents and some symbols (finding 23). The contract
promises only case-insensitive equality; the mock behaves like Meilisearch (the stricter one). The
guide says: keep codes (ASCII, no symbols) in keyword fields used for exact filters.

### 3.6 Search

```pascal
R := Index.Search('café preto')
  .Where(Filter)
  .OrderBy('price', soAsc).ThenBy('created_at', soDesc)
  .Page(1, 20)                     // 1-based; at most 250 per page
  .Facets(['category', 'tags'])
  .Fields(['id', 'title'])         // empty: every stored field
  .Words(swAll)                    // default; swRelaxed: the engine drops trailing words
  .Execute;

R.Total; R.Page; R.PageSize; R.Count; R.Hits[I].Id; R.Hits[I].Document (TJsonValue, owned by R);
R.Facet('category').Count; .Value[J]; .ValueCount[J];
```

**S15. The text is words, by default.** Both engines read `-word` as "without word" and `"..."`
as a phrase (finding 13); a user typing `-café` or a stray quote gets a surprising answer. With
`TextMode = tmWords` (default) the library removes a leading `-` from each word and every `"`
before sending; `tmEngine` sends the text as typed. Nothing else needs cleaning: no input made
either engine fail (finding 12). Case, accents and a prefix on the last word work the same on both
(findings 14, 15); typo tolerance differs (finding 16) and is left to each engine's settings.

**S16. Every word is required, by default.** Both engines drop words by default until something
matches (finding 17), which makes "café x" find every coffee. `swAll` maps to Meilisearch
`matchingStrategy: all` and Typesense `drop_tokens_threshold=0`; `swRelaxed` to `last` and
`drop_tokens_threshold=1`. The query searches the schema's `Text` fields (Typesense `query_by`),
so both search the same fields (finding 18).

**S17. Paging is page + page size, with an exact total.** Meilisearch's `page`/`hitsPerPage` gives
an exact `totalHits`; `offset`/`limit` only an estimate (finding 33). Page size 1-250 (Typesense's
limit, finding 34); page size 0 gives the total and the facets only. Meilisearch never returns a
hit past `maxTotalHits` (1000 by default) even though the total counts them (finding 33): the
schema has `MaxReachableHits` (default 1000), set by `EnsureIndex` on Meilisearch and ignored by
Typesense; a page beyond it raises `ESearchArgumentError` instead of coming back empty.

**S18. No sort means "the engine's relevance"**: with text, by relevance; without text, the order
is unspecified (Meilisearch oldest first, Typesense newest first, finding 19). Documents without
the sort field come last in both directions on both engines (finding 32), and in the mock.

**S19. Facets return value and count**, values as stored (finding 35). Numeric facet statistics
(min/max) are Meilisearch only: native.

### 3.7 Native access

**S20. Each adapter exposes its engine.**
- Engine level: `(Engine as IMeilisearchEngine).Send(Method, Path, Body)` /
  `ITypesenseEngine.Send(...)`, with the key, the base URL and the error mapping already applied;
  typed helpers for what is common to need (Meilisearch: settings such as synonyms, typo
  tolerance, ranking rules; Typesense: synonyms, curation).
- Query level: `.Raw('name', JsonValueText)` adds an engine parameter to the search
  (a member of Meilisearch's body, a query parameter on Typesense), and `R.RawJson` is the
  engine's answer as received. The mock refuses `Raw` (`ESearchNotSupported`), so a test notices
  code that depends on an engine.

### 3.8 Errors

**S21. One base class, a few subclasses chosen by what the caller does next.**

| Class | When | Caller's next step |
|---|---|---|
| `ESearchUnavailable` | no answer (transport), a 5xx | retry later; an API answers 503 |
| `ESearchAuthError` | 401, 403 (Meilisearch `invalid_api_key`, `missing_authorization_header`; Typesense 401 for both, finding 37) | fix the configuration |
| `ESearchIndexNotFound` | Meilisearch `index_not_found`; Typesense 404 "Collection not found" | `EnsureIndex` |
| `ESearchRequestError` | any other 4xx: an undeclared filter/sort field, a bad value, a 422 | a bug in the caller |
| `ESearchWriteFailed` | `WaitFor` found refused documents (S7) | fix or skip them |
| `ESearchTimeout` | `WaitFor` limit reached, the write still pending | wait again or alert |
| `ESearchSchemaError` | `EnsureIndex` can't change the index in place | rebuild the index |
| `ESearchArgumentError` | refused at the call: id, index name, field name, backtick on Typesense, page size, NaN | a bug in the caller |

All carry `HttpStatus`, `EngineCode` (Meilisearch's `code`; empty on Typesense, which sends a
message only) and `EngineMessage`. Typesense's 404 for a missing field is a request error, not a
missing index: the adapter tells them apart by the message ("Collection not found"), the only
signal Typesense gives. `Get` of a missing document returns `False`, not an exception.

### 3.9 Configuration and threads

**S22.** `TMeilisearchConfig` / `TTypesenseConfig`: base URL, API key, timeout per request,
default `WaitFor` limit, TLS options of pascal-common-faa's transport (private CA). An engine
object is safe to share between threads: each call is its own HTTP exchange, as the transport
already works. Settled with the Meilisearch adapter (2026-11-10, the user's choices): the record
holds pascal-common-faa's whole `TPcHttpOptions` as `Http` (`Http.Tls.CaFile`, mTLS, the pool),
not flat `Tls*` fields, so a new transport option needs no change here; the library reads no
environment variables (no standard names exist for these clients; the application fills the
record from its own configuration). One engine owns one transport, kept alive for its pool. Callbacks, where there are any (the outbox bridge's document loader),
follow pascal-db-faa: `reference to` on Delphi, `of object` on FPC (`PASCALSEARCH_FUNCREFS`).

## 4. The mock

**S23. `TMockSearchEngine`, the same contract in memory**, with the behavior the probe measured
where the engines agree, and Meilisearch's where they don't (the stricter):
- schema checks: filter, sort and facet only on declared fields (`ESearchRequestError`);
- text: `PcFoldForSearch` on words (case and accents folded), every word required, a prefix on
  the last word, `swRelaxed` drops trailing words until something matches; **no typo tolerance**
  (documented: a test that needs typos runs against an engine);
- filters as in S11-S14, missing fields as in S12, sort with missing values last;
- writes visible at once, unless `DeferWrites := True`: then a write is visible only after its
  `WaitFor`, so a test catches code that searches before waiting (the Meilisearch behavior);
- failure injection: `FailNextWrite(Ids, Message, WholeBatch)`, `Unavailable := True`.

## 5. Tests

**S24. One contract suite for every engine**, like pascal-db-faa's: the same test bodies run
against the mock (unit suite, no container), Meilisearch and Typesense (integration suite,
Docker, versions pinned: `getmeili/meilisearch:v1.56.2`, `typesense/typesense:30.2`). DUnitX
masters in the FPCUnit assertion dialect, mirrors generated by `tools/gen_fpc_mirror.py`;
0 leaks on both sides. The filter writers (S13) also get plain unit tests on their output text,
with the probe's hostile values (quotes, backslashes, backticks, `||`, `&&`).

## 6. Order of work

1. pascal-common-faa: the HTTP transport (its own plan; adapters wait for it). Done: 1.31.0.
2. Here: skeleton; core (schema, documents, filters, errors), mock, unit suite. Done.
3. Meilisearch adapter + integration suite. Done (section 9).
4. Typesense adapter: if a contract test has to be bent for it, the contract changes, not the test.
5. Outbox bridge, sample, guide; entry in `faa-libraries.md` once a version is published.

## 7. Questions closed at acceptance

- S9: milliseconds.
- S15/S16: words-only text and every word required by default. The engines' own defaults are the
  opposite; these favor predictable results over recall.
- S5: the common id set only; no option for an engine's wider set.

## 8. What the implementation settled (0.1.0, core and mock)

- **Builder names** `Num`, `Int`, `Bool` instead of `Number`, `Integer`, `Boolean`: a method
  named `Integer` would hide the type inside the class. The document builder uses the same
  names (`Str`, `Strs`, `Num`, `Int`, `Bool`, `Instant`, `Null`, `Json`).
- **`Get` returns an `ISearchHit`** (nil when missing) instead of an `out TJsonValue` the caller
  frees; `GetMany` returns `ISearchHits`. No manual free anywhere in the contract.
- **`EnsureIndex` returns when the index is ready**: on Meilisearch its adapter waits for the
  settings tasks itself (a filter right after a settings call failed, finding 3).
- **`ESearchSchemaError` only where the engine has field kinds**: Meilisearch has none, so a
  kind change applies there in place; the mock and Typesense refuse it. Not a contract test.
- **A write to an index never ensured** raises `ESearchIndexNotFound` at the call on the mock
  (and Typesense, 404). Meilisearch would create the index without a schema: its adapter checks
  the index first.
- **Facet values are sorted by the library** (count descending, then value by ordinal), so
  every adapter returns the same order (`TSearchResult.AddFacet`).
- **No hit past `MaxHits`** on any engine: Typesense has no such limit, so its adapter cuts the
  page itself.
- **Failures are always raised by `WaitFor`**, also on Typesense, which knows them at the call:
  one place to handle them.
- **`Words(swRelaxed)` in the contract only when no document matches every word**: when some
  do, Meilisearch still adds those matching fewer and Typesense doesn't (`café preto`: 3,1 vs 3).
- The text of a `tmWords` query (`SearchWordsText`) drops `"` and a leading `-` of each word,
  and nothing else: no input made either engine fail (finding 12).
- The mock compares strings ignoring case only (`PcLowerCase`), like Meilisearch; it refuses a
  filter value whose kind doesn't fit the field (`ESearchRequestError`).

## 9. What the Meilisearch adapter settled (0.1.0)

- **Its own package and folder**, as section 2 says: `adapters/meilisearch/`,
  `pascal_search_faa_meilisearch.lpk`. The core keeps pascal-common-faa 1.20.0 as its minimum;
  only the adapter needs 1.31.0 (checked with `$MESSAGE FATAL` in the unit).
- **A write that got no answer raises `ESearchUnavailable` and is not sent again** (the user's
  choice). Writes are POST, which the transport never repeats; Meilisearch may have queued the
  task or not, and a second send would be a second task. Upsert and Delete are idempotent, so
  the caller (or the outbox bridge) repeats them.
- **Every write first checks the index** (`GET /indexes/{uid}`, about 0.3 ms on a kept-alive
  connection), because Meilisearch creates a missing index on the first write without the
  schema (finding 8). Two requests, so an index dropped between them is still created; the doc
  says so.
- **`MaxHits` for an index this engine didn't ensure** is read once from
  `/settings/pagination` and cached; `EnsureIndex` and `DropIndex` update the cache. Only a page
  past the first needs it.
- **Facets**: the settings sort facet values by count (finding 48), so Meilisearch's cut at
  `maxValuesPerFacet` (100) keeps the most frequent; the library still orders them
  (`TSearchResult.AddFacet`). Meilisearch facets any filterable field (finding 45): the contract
  test now asks for a facet on a field that is neither filterable nor a facet, and the mock's
  stricter refusal is a mock test.
- **`DeleteWhere` that fails in its task raises `ESearchRequestError`** (no documents to list);
  a failed Upsert or Delete raises `ESearchWriteFailed` with every id and `WholeBatch`. A task's
  `index_not_found` raises `ESearchIndexNotFound` in both cases.
- **`Raw` replaces a parameter of the same name** (`matchingStrategy`, `filter`...) instead of
  sending it twice.
- **An empty write sends nothing** after the index check, and its `WaitFor` returns at once.
- **The contract suite assumed no typos** in one place (`mineiro` matched `mineira`, finding 47);
  it now searches a word no text field comes close to (gotcha 6).
