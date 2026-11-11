# 8. What each engine does differently

The same contract suite passes on the mock, Meilisearch 1.56.2 and Typesense 30.2. The library
evens out most differences the probe found ([`engine-findings.md`](engine-findings.md), cited
as "finding N"); these still show, and each has a rule that avoids it.

| | Meilisearch | Typesense | Rule |
|---|---|---|---|
| Writes | a task, applied later (findings 1-3) | applied before the answer (finding 4) | always `WaitFor` before searching what you wrote |
| A refused document | the whole batch fails, `WholeBatch` (finding 2) | only it; the others kept (finding 5) | handle `ESearchWriteFailed` from `WaitFor`, not from the call |
| `Eq` on a string | folds case (finding 23) | folds case, accents and some symbols | keep codes ASCII in keyword fields filtered by equality |
| Typo tolerance | its own (finding 16) | its own | a test that expects no match picks a word nothing comes close to (gotcha 6) |
| No sort, no text | oldest first (finding 19) | newest first | sort explicitly when the order matters |
| `swRelaxed` when some documents match every word | also adds those matching fewer | doesn't | rely on `swRelaxed` only when nothing matches every word |
| Facets | any filterable field (finding 45) | only `facet: true` fields | declare `sfFacet` for every facet (gotcha 7) |
| Hits past `MaxHits` | never returned, though counted (finding 33) | the adapter cuts them | a page past `MaxHits` raises `ESearchArgumentError` (gotcha 5) |
| A backtick in a filter value | quoted and escaped | nothing escapes it (finding 22) | refused with `ESearchArgumentError` on Typesense (gotcha 3) |
| Sort keys | any number | at most 3 (finding 50) | a fourth is Typesense's 400, `ESearchRequestError` |
| Changing a field's kind | in place | refused by the library (`ESearchSchemaError`), as on the mock | drop and rebuild the index |
| Facet statistics, `EXISTS`, `IS NULL` | yes | no | native access, Meilisearch only |
| Highlight of a field that isn't Text | highlighted | refused (`ESearchRequestError`), as on the mock | highlight Text fields only |
| What a highlight marks | its own matching (prefix part, typos) (finding 64) | the same rules, its own typos | read `Parts`/`ToHtml`, never assume whole words |
| Where an index lives | an index (finding 57) | an alias to `name@<n>` since 0.2.0 (findings 59, 70) | let `ReplaceIndex` and `DropIndex` manage them |
| `ReplaceIndex` onto a 0.1.0 index | atomic | a few ms of `ESearchIndexNotFound` (finding 60) | once per index; afterwards atomic |
| Synonyms | the index's setting (finding 66) | a global set named like the collection (findings 67, 68) | set them only through `SetSynonyms` |
| Typo, ranking, stop words, curation | settings (`SetTypoTolerance`...) | curation sets (`SetCuration`), typos per query (`Raw`) | native access |

What the library makes the same, so you don't have to think about it: the schema (searched,
filtered, sorted and faceted fields, findings 8, 18, 20, 32, 35); ids (the common set, findings
9-11); instants as Unix ms and numbers without exponents (findings 24, 26); a missing id deleted
without error (finding 7); the words of the text and "every word" (findings 13, 17); paging with
an exact total (finding 33); documents without the sort field last (finding 32); facet values
ordered the same way; error classes.
