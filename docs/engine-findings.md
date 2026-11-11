# Engine probe findings (2026-11-09)

What Meilisearch and Typesense answered to the requests a search library sends, measured before
designing the contract. `docs/design.md` cites these by number ("finding N"). The probe itself
(`EngineProbe.lpr`, its step files, `run.sh`, the raw output) is throwaway and git-ignored in
`.ci/probe-engines/`; this file is the record.

EngineProbe.lpr, FPC 3.2.2 on Linux (Debian 12 bookworm, OpenSSL 3.0), every request through
pascal-api-infra-faa's `PascalApi.HttpTransport` (source 0.32.1, pascal-common-faa 1.30.0).
Engines in Docker: `getmeili/meilisearch:v1.56.2` (master key), `typesense/typesense:30.2`
(single node, API key). Steps: `meili.steps`, `typesense.steps`, `*-tls.steps`; output:
`out-all.txt` (`run.sh` rebuilds everything). heaptrc: 0 unfreed blocks on every run.
Same seven documents on both (accents, a category with quotes, one with backslashes, one with a
backtick, one without category/price/available, one with `available: null`), plus 1500 generated
ones for paging. Not measured: Delphi (IDE only), load, a Typesense cluster.

## A. Writes and consistency

1. **Meilisearch writes are asynchronous.** Every write (create index, settings, add, delete,
   delete index) answers 202 with a `taskUid`; the outcome is only in `GET /tasks/{uid}`
   (`succeeded`/`failed`, `error` with the same shape as an HTTP error, `details` with counts).
   Invalid documents (bad id, missing id) are accepted with 202 and fail in the task.
2. **A Meilisearch task is atomic**: a batch with one invalid id failed whole (3 received, 0
   indexed; `good1` absent afterwards). Per-document failures cannot be reported.
3. **Time to visible** (Meilisearch, one document, idle server, polling every 1-2 ms): 25-60 ms
   until a search finds it; 36 ms until its task succeeds; 1500 documents: 94 ms. A search right
   after the 202 found nothing. A filter on an attribute declared filterable one call earlier
   still failed (400) until the settings task ended. Integration tests must wait for the task.
4. **Typesense writes are synchronous**: the answer comes after indexing; the document was found by
   the first search (1 poll, 1-2 ms), single document and import alike. No task id.
5. **Typesense import is not atomic and always answers 200**: one JSON line per document,
   `{"success":false,"code":400,"error":"..."}` for the bad ones; the good lines of the same
   import are kept (`good3` indexed after two bad lines and a non-JSON line).
6. **Replace vs merge.** Meilisearch: `POST /documents` replaces (doc 7 lost its other fields),
   `PUT /documents` merges. Typesense: `action=upsert` replaces (and every non-optional schema
   field must be present, else 400), `action=update` and `PATCH /documents/{id}` merge;
   `update` of a missing id is 404; `emplace` creates or merges but needs the required fields to
   create.
7. **Deletes.** Meilisearch: deleting a missing id succeeds (`deletedDocuments: 0`); batch by ids
   and by filter. Typesense: `DELETE /documents/{id}` of a missing id is 404; delete by
   `filter_by=id:[...]` answers `num_deleted` and ignores missing ids.
8. **Index/collection.** Meilisearch: creating an existing index fails in the task
   (`index_already_exists`); adding documents to a missing index creates it (the primary key is
   inferred from a field ending in `id`, else the task fails
   `index_primary_key_no_candidate_found`); uid limited to `[A-Za-z0-9_-]` (400 otherwise).
   Typesense: a schema up front (types, `optional`, `facet`, `sort`); existing name 409; adding to
   a missing collection 404 (no auto-create); the name `a b` was accepted.

## B. Ids

9. **Meilisearch**: integer or string of `[A-Za-z0-9_-]`, at most 511 bytes. Rejected in the task:
   space, `/`, `.`, `á`, empty, float, boolean, 512 bytes. Integer `123` and string `"123"` are
   the same document (the second write won). `-1` was accepted.
10. **Typesense**: `id` must be a JSON string (`123`, `-1`, `true`: 400); any characters work
    (`a b`, `a/b`, `á`, `a"b,c`, 2000 bytes; GET with the id percent-encoded in the path); empty
    is 400; missing on create gets a generated id (`"7"`), missing on update is 400.
11. Common ground: a string id of `[A-Za-z0-9_-]`, 1-511 bytes. Meilisearch reports a bad id only
    in the task, so checking it before sending gives the error at the call.

## C. Text search

12. **No input raised an error on either engine** (49 inputs: the 28 of pascal-db-faa's FTS probe,
    its 25 option inputs, typos): `"café`, `café)`, `-café`, `*`, `+`, `NEAR(...)`, `a & b`,
    `café:*`, `50%`, `d'água`, empty, blanks. Compare FTS5: 13 of 28 errored. No sanitizer needed.
13. **But the text has operators on both**: a leading `-word` excludes (`-café` -> 2,4,5,6,7;
    `café -preto` -> 1) and `"..."` is a phrase (`"café preto"` -> 3). `OR` is a plain word.
14. **Case and accents folded on both**, query and documents: `café`/`cafe`/`CAFÉ`,
    `agua`/`água`, `fuba`/`FUBÁ`. No Portuguese stemming; `cafés` and `amendoins` matched through
    typo tolerance.
15. **Prefix on the last word on both** (`pre`, `caf`, `ca`, `c`, `açú`, `agu`, `polvi`). A `*`
    suffix: Meilisearch `caf*` -> none, Typesense `caf*` -> 1,3.
16. **Typos differ.** Meilisearch: one typo from 5 letters (`queiju`, `moleqe` yes; `cafr`, `itme`
    no). Typesense: `cafr` -> 1,3 and `itme` -> all 1500.
17. **Several words, by default, both drop words until something matches.** Meilisearch
    `matchingStrategy: last` (`café x` -> 1,3); Typesense `drop_tokens_threshold` 1 (`xyz leite` ->
    1, `a & b` -> 6,4,1). "Every word required": Meilisearch `matchingStrategy: all`, Typesense
    `drop_tokens_threshold=0`; with them both gave the same ids on the inputs except
    `Café-com-leite` (Meilisearch 1, Typesense none) and `bebida quente` (see 18).
18. **Searched fields.** Meilisearch searches every attribute by default (`searchableAttributes:
    ["*"]`: `bebida quente` found doc 3 through `category`/`tags`); Typesense searches only the
    `query_by` fields, which a non-`*` query requires (400 "No search fields specified"), and
    only string fields of the schema (an extra field: 404).
19. Empty or blank text returns every document on both. Without text and without sort the order
    differs: Meilisearch insertion order (`b1`...), Typesense newest first (`b1500`...).

## D. Filters

20. **Declaration.** Meilisearch: only attributes in `filterableAttributes` (a settings task),
    else 400 `invalid_search_filter`. Typesense: any indexed schema field; an unknown one 400.
21. **Meilisearch quoting is safe when done right**: `"..."` or `'...'`, backslash escapes the
    quote and itself (`"Bar \"Zé\""` -> 4, `"C:\\doces\\"` -> 5, `'x\'y`z, w'` -> 7). A lone
    backslash before the closing quote is a 400. A user value concatenated unquoted changes the
    filter (`category = bebida OR price > 0` -> 6 docs); quoted and escaped it doesn't (-> none).
22. **Typesense has no escape that holds.** Backticks wrap a value with spaces, quotes, `||`,
    `&&`, `(`, `)` safely (`` `bebida || price:>0` `` -> none; `` `Bar "Zé"` && price:>0 `` -> 4;
    `` `C:\doces\` && price:>0 `` -> 5). But:
    - a backtick inside a value cannot be written: `` \` ``, a doubled backtick and `"...\"..."`
      all let the rest through (`` `x\` || price:>0 || category:=\`y` `` -> 6 docs, the same with
      double quotes), and a value with a backtick plus `&& price:>0` matched nothing;
    - inside a list `[...]` a backslash does escape: `` [`C:\doces\`, bebida] `` -> none,
      `` !=[`C:\doces\`, bebida] `` -> all 7, while the same values joined with `||` -> 5,4.
    So: backticks, refuse a value with a backtick, and write `In`/`NotIn` as `||`/`&&` of single
    comparisons, never as a list.
23. **Equality differs.** Meilisearch `=` folds case only (`tags = cafe` -> none, `tags = CAFÉ` ->
    1,3). Typesense `:=` folds case, accents and some symbols (`tags:=cafe` -> 1,3,
    `` `C:\doces` `` matched `C:\doces\`); `:` is a token match (`category:BEB` -> none).
24. **Numbers.** Meilisearch compares numerically even quoted (`price > "5"` -> 1,2,4) and answers
    0 hits, not an error, to `price > abc` and `price > 1e1`. Typesense wants bare numbers (a
    backticked number or `abc`: 400 "Not a float"); `1e1` -> none. Write numbers in plain decimal
    with a `.` whatever the locale.
25. **Booleans**: `true`/`false` on both; Meilisearch also `"true"`, `1` -> none; Typesense `1` or
    `` `true` `` -> 400.
26. **Dates**: neither compares date strings (`created_at > "2026-01-01"`: Meilisearch 0 hits
    silently, Typesense 400). A date must be indexed as a number (Unix time); the library has to
    convert, since Meilisearch fails silently.
27. **Missing and null.** Meilisearch: `EXISTS`, `NOT EXISTS`, `IS NULL` (explicit null only),
    `IS EMPTY`, `IS NOT NULL`. Typesense 30.2: nothing measured works (`category:=null` compares
    with the text "null"; `available:=null` 400; `tags:=[]` -> none). Not portable.
28. **Negation.** `!=` and `NOT IN` include documents without the field on both (`category !=
    bebida` -> 2,4,5,6,7, doc 6 has no category). Typesense 30.2 has no negation of a group
    (`!(...)` 400); Meilisearch's `NOT price > 5` includes doc 6 (no price) while `price <= 5`
    excludes it on both. Portable: `NotEq`/`NotIn`; a negated range or group is not.
29. Range and comparisons: `price 5 TO 8` / `price:[5..8]`, `>`, `>=`, `<`, `<=` on both, same ids.
    Arrays: `tags = café` matches a document whose array holds it, on both.
30. Meilisearch-only: `STARTS WITH`; `CONTAINS` needs an experimental feature (400
    `feature_not_enabled`); the array form `[["a","b"],"c"]` = (a OR b) AND c.
31. An empty filter is no filter on both. A syntax error is 400 on both (Meilisearch with the
    position).

## E. Sort

32. Meilisearch: only `sortableAttributes` (400 `invalid_search_sort`). Typesense: numbers and
    booleans sortable by default, strings with `sort: true`; an unknown field is **404**.
    Documents without the field come last in both directions on both. String order folds accents
    on both (`Água` first). Several keys on both.

## F. Paging and totals

33. **Meilisearch**: `offset`/`limit` give `estimatedTotalHits`; `page`/`hitsPerPage` give
    `totalHits` and `totalPages`. Default `pagination.maxTotalHits` = 1000: hits past the 1000th
    are never returned although the totals say 1500 (`limit` 5000 -> 1000 hits, `offset` 998 -> 2,
    page 334 of 3 -> 1); raising it to 5000 brought them back. `limit 0`/`hitsPerPage 0` give
    counts only; page 0 gives no hits; a negative offset 400.
34. **Typesense**: `page`/`per_page` and `offset`/`limit`; at most 250 per page (422 above,
    `limit` included); page 0 is page 1; `found` exact (`out_of` = collection size); past the end
    empty.

## G. Facets

35. Meilisearch: facet attributes must be filterable; `facetDistribution` (value -> count; a
    boolean as "true"/"false"), `facetStats` min/max for numbers; a facet-search endpoint.
    Typesense: `facet: true` in the schema (else 404); `facet_counts` per field with value, count,
    highlighted, and `stats`; `facet_query` for a prefix. Values come back as stored on both
    (accents, quotes, backslashes intact).

## H. Hydration

36. Both return only the fields asked (`attributesToRetrieve` / `include_fields`). Highlight:
    Meilisearch `_formatted` with `<em>`, Typesense `highlight(s)` with `<mark>`. Score:
    Meilisearch `_rankingScore` 0..1 when asked, Typesense `text_match` (a large integer). By
    ids: Meilisearch `POST /documents/fetch {"ids":[...]}` (missing ids left out), Typesense a
    filter `id:[...]`. Typesense stores fields outside the schema and returns them, but can't
    search them.

## I. Errors

37. Meilisearch: `{message, code, type, link}`; `index_not_found` 404, `document_not_found` 404,
    `invalid_api_key` 403, `missing_authorization_header` 401, `malformed_payload` 400,
    `invalid_search_*` 400; task errors have the same shape. Typesense: `{message}` only, no code;
    404 for a missing collection, document or field (also an unknown sort field), 409 exists, 401
    for a wrong or a missing key (same message), 400 bad JSON, type or filter, 422 page size.
38. An unknown search parameter: Meilisearch 400, Typesense ignores it. Meilisearch also accepts a
    single object as the documents body. `/health` needs no key on either.

## J. Transport and TLS (FPC 3.2.2, Linux)

39. Refused port: `EHttpTransport` in 1 ms; unknown host in 55-131 ms; an unroutable address at
    the 5 s `TimeoutMs`.
40. **https fails on Debian 12 as it comes**: "Could not initialize OpenSSL library". The image has
    only `libssl.so.3`/`libcrypto.so.3`; FPC 3.2.2's openssl unit finds OpenSSL 3 only through the
    unversioned `libssl.so`/`libcrypto.so` (package `libssl-dev`). After installing it, https
    worked against both engines.
41. **fphttpclient verifies nothing**: once loaded, it accepted a self-signed certificate and a
    host name the certificate doesn't name, on both engines. A man in the middle gets the API key.
42. **Plain http to a TLS port gave status 0 with an empty body and no exception**, while
    `PascalApi.HttpTransport` documents `EHttpTransport` for "an answer that isn't HTTP".
43. Keys: Meilisearch `Authorization: Bearer <key>`, Typesense `X-TYPESENSE-API-KEY: <key>`.

**40-42 are resolved on pascal-common-faa 1.31.0** (`PascalCommon.Http`, its own HTTP/1.1
client), which the adapters use instead of fphttpclient. Measured 2026-11-10 by the
integration suite against Meilisearch v1.56.2 over https, with a certificate from a private CA
(`tools/engines.sh`), on FPC 3.2.2 Linux (OpenSSL 3, Debian 12 with `libssl3` only, no
`libssl-dev`) and FPC 3.2.2 Windows (SChannel, the CA as PEM): the CA in `Tls.CaFile` accepted;
the system store refused it; a host name the certificate doesn't hold (`127.0.0.1`,
`meili-tls-other`) refused; plain http to the TLS port raised (`ESearchUnavailable`, no status)
instead of answering status 0.

## K. Found while building the Meilisearch adapter (2026-11-10)

Meilisearch v1.56.2, measured by `tests/Integration` (not by the probe).

44. **`_geo` is validated only once it is filterable or sortable**: a document with `"_geo":
    "nowhere"` was indexed on an index that didn't declare it; with `_geo` filterable the task
    failed (code with `geo` in it) and the whole batch with it (finding 2).
45. **Meilisearch facets any filterable attribute**: `facets: ["price"]` on a field declared
    filterable answered a distribution. There is no "facet only" declaration (finding 35 says a
    facet must be filterable; the reverse holds too). Typesense refuses a field without `facet:
    true`, and so does the mock.
46. `searchableAttributes: []` is accepted: no attribute is searched, so any word matches
    nothing and an empty text still matches every document (the mock's behavior).
47. Typo tolerance (finding 16) found `mineira` for `mineiro` (7 letters, one typo): a test
    that expects a word not to match must pick one no text field comes close to.
48. Accepted by the settings call as sent: `faceting.sortFacetValuesBy: {"*": "count"}`,
    `filterableAttributes` with `id` in it, `pagination.maxTotalHits`.

## L. Found while building the Typesense adapter (2026-11-10)

Typesense 30.2, measured with curl against a throwaway container and by `tests/Integration`.

49. **Collections keep a `metadata` object**: given on `POST /collections`, returned by `GET`,
    replaced whole by `PATCH /collections/{name}` (alone or with `fields`).
50. **At most 3 sort keys**: a fourth is 400 "Only upto 3 sort fields are allowed."
51. `include_fields` without `id` returns documents without their id.
52. `PATCH` with a field dropped and added again in the same request (`{"name":"x","drop":true}`,
    then its new definition) is accepted and reindexes the stored documents: a field made a
    facet afterwards counted the documents already there. Changing the type the same way was
    accepted too (the library refuses it, section 10 of the design).
53. **`DELETE /collections/{name}` of a missing collection** answers 404 "No collection with name
    `x` found.", not "Collection not found" (search, get and writes).
54. A boolean facet's values are `"true"` and `"false"`, as on Meilisearch.
55. An import line with a value of the wrong type (`"price":"abc"` on a float) is refused with
    code 400 "Field `price` must be a float."; the other lines are kept (finding 5).
56. The contract suite (39 tests) passed on Typesense without a change, and on Meilisearch:
    the common ground of section D-H holds through the adapters.

## M. Probed for 0.2.0 (2026-11-11)

Meilisearch v1.56.2 and Typesense 30.2 in throwaway containers, requests from a Python script
(`.ci/probe-v02/`, git-ignored; `out-*.txt` is the raw output). Same kind of documents as section
A (accents, HTML in a value, a document without some fields), plus 1500 generated ones.

### Replacing an index

57. **Meilisearch `POST /swap-indexes`** (`[{"indexes": ["a", "b"]}]`) is one task that swaps the
    whole indexes: documents and settings (`filterableAttributes`, `pagination.maxTotalHits`).
    A missing index fails the task (`index_not_found`) and nothing changes.
58. **Meilisearch renames**: `"rename": true` in a swap renames `a` to `b` when `b` doesn't exist
    (`index_already_exists` in the task when it does); `PATCH /indexes/{uid}` with `{"uid": ...}`
    renames too. Both are tasks.
59. **Typesense aliases**: `PUT /aliases/{name}` `{"collection_name": ...}`. Search, import, get,
    delete by filter, `PATCH /collections/{alias}` (metadata) and `GET /collections/{alias}` all
    resolve an alias (the GET answers with the collection's own name and metadata). Repointing is
    one PUT. An alias to a missing collection is accepted, and dropping a collection leaves its
    alias dangling: a search through it is 404 "Collection not found".
60. **Typesense names**: an alias named like an existing collection is refused (500 "conflicts
    with an existing collection name"), but a collection can be created with an alias's name, and
    then the collection wins (`DELETE /collections/p` dropped the collection `p`, not the alias's
    target). Deleting a missing alias: 404 "Collection not found". **No rename**: `PATCH` accepts
    only `fields`, `metadata` and `synonym_sets` (400 otherwise). Alias names take any character
    (`a b`).

### Listing every id

61. **Neither listing is capped like search.** Meilisearch `GET /indexes/{uid}/documents` and
    `POST .../documents/fetch` page with `offset`/`limit` past `maxTotalHits` (offset 1490 of
    1500 with `maxTotalHits` 1000; `limit` 100000 returned all 1500), take `fields`, and `fetch`
    takes a `filter` (filterable attributes only; `sort` needs sortable ones). The order is the
    engine's: insertion order, a rewritten document keeps its place, a new one goes last; an
    offset past the end is empty. Typesense `GET /collections/{name}/documents/export` answers
    every document as JSON lines, honors `include_fields` and `filter_by`, has no `limit` (ignored),
    same order (a new document last); a missing collection is 404 "Collection not found".

### Highlight

62. **Meilisearch**: `attributesToHighlight` (names or `*`), `highlightPreTag`/`highlightPostTag`
    (default `<em>`); the hit's `_formatted` holds every retrieved attribute, plus the highlighted
    ones even when not retrieved, with the whole value. Numbers come back as strings there; each
    element of an array is highlighted. Any attribute is highlighted, also one that isn't
    searchable (`cat`, when the word matched another field). An unknown attribute: no
    `_formatted` at all. Empty text: values without tags.
63. **Typesense**: `highlight` per field: `snippet` (the whole value under `snippet_threshold`, 30
    tokens; above it a window of `highlight_affix_num_tokens`, 4, each side), `value` (the whole
    value) for the fields in `highlight_full_fields`, `matched_tokens`. An array gives one entry
    per element. Tags `<mark>` by default, `highlight_start_tag`/`highlight_end_tag`. Without
    `highlight_fields` only the `query_by` fields that are also returned (`include_fields`) are
    highlighted; `highlight_fields` names any string field, returned or not. The old
    `highlights` array comes too unless `enable_highlight_v1=false`. A field without a match is
    left out of `highlight`.
64. **Both**: a prefix marks only the matched part (`<em>Caf</em>é`), a typo or a folded accent
    the whole word (`queiju` -> `<mark>queijo</mark>`, `agua` -> `<em>Água</em>`); **neither
    escapes HTML**: `<script>alert(1)</script>` and `<b>` come back as stored, next to the tags.
65. Cropping differs: Meilisearch `attributesToCrop`/`cropLength` in words with a `cropMarker`
    (`…`); Typesense a window of tokens around each match, without a marker, only above the
    threshold. No common ground.

### Synonyms, typos, ranking, curation

66. **Meilisearch synonyms**: the setting `synonyms` `{word: [words]}`, one way per key (each
    word a key gives a group); keys and values can be several words; case and accents folded
    (`televisao`, `TV`, a key `Geladeira`). `PUT` replaces them all, `{}` clears; a task. A value
    that isn't an array is 400 at the call.
67. **Typesense 30.2 synonyms are global sets**: the per-collection `/collections/{name}/synonyms`
    is gone (404). `PUT /synonym_sets/{name}` `{"items": [{"id", "synonyms", "root"?}]}`: without
    `root` the words are all equivalent, with it `root` -> `synonyms` one way; an item needs an
    `id` (400). A collection uses a set through its `synonym_sets` (at creation or by `PATCH`), or
    a search through `synonym_sets=`. Case and accents folded. `PUT` replaces the items. Set names
    take any character; sets survive the collection's drop; attaching a missing set is 404.
68. **Deleting a Typesense synonym set still attached breaks every search on the collection**:
    404 "Synonym index not found" until the set is detached or created again. Deleting a curation
    set in use is harmless.
69. **The rest is per engine.** Typesense 30.2 curation is global sets too (`/curation_sets/{name}`,
    items with `rule` `{query, match}`, `includes` with positions, `excludes`; attached by
    `curation_sets`; the per-collection `overrides` endpoint is gone), and typo settings are search
    parameters (`num_typos`...), not collection settings. Meilisearch `typoTolerance`
    (`enabled`, `minWordSizeForTypos`, `disableOnWords`, `disableOnAttributes`), `rankingRules`
    and `stopWords` are settings (tasks; a bad ranking rule is 400 at the call; `GET` shows the
    1.56 names `attributeRank` and `wordPosition`).
70. **A Typesense collection named `prod@1794403251000`** (an `@` and digits; `x y` too) works
    behind an alias `prod`: import, search, export, `PATCH` of `fields`, `metadata` and
    `synonym_sets`, all through the alias, with the `@` percent-encoded where the collection is
    named in a path. `GET /collections/{alias}` answers with the collection's own `name`, and
    `GET /aliases/{name}` with `collection_name` (404 "Collection not found" for no alias). A
    synonym set can carry the collection's name; deleting it after the collection is harmless.
71. **Control characters as highlight tags**: `highlightPreTag` `"\u0001"` / `highlightPostTag`
    `"\u0002"` (Meilisearch) and `highlight_start_tag=%01` / `highlight_end_tag=%02` (Typesense)
    come back as given around each match (`\u0001Caf\u0002é com leite` on both).
