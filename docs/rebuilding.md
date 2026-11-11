# 9. Rebuilding an index

A schema change the engine can't make in place (`ESearchSchemaError`), new synonyms or settings
to try, a resync after dead outbox deliveries: the index has to be filled again from the
database. Since 0.2.0 that happens **beside** the live index, which keeps answering, and one
call puts the new one in its place (design S25-S26).

```pascal
Engine.DropIndex('products_new');                          // a leftover of a failed run
Staging := Engine.EnsureIndex(SearchSchemaRenamed(ProductsSchema, 'products_new'));
Staging.SetSynonyms(LGroups);                              // and any native setting
... // fill it: Staging.Upsert(...) page by page, or a TSearchOutboxHandler on it and Sync
Engine.ReplaceIndex('products', 'products_new');
```

When `ReplaceIndex(Target, Source)` returns, `Target` serves what `Source` held: its documents,
its schema, its synonyms and every engine setting. The name `Source` is free again, and what
`Target` held is gone. `Target` may not exist yet (then it is a rename). A missing `Source`
raises `ESearchIndexNotFound`.

**Set everything on the new index before replacing**: synonyms (`SetSynonyms`) and the native
settings (`SetTypoTolerance`, `SetRankingRules`, `SetStopWords`, `SetCuration`) belong to the
index and travel with it; the live index's go away with it.

## What each engine does

- **Meilisearch** swaps the two indexes in one task (atomic), then drops the source, which then
  holds the old documents; a missing target is a rename. Each task is waited.
- **Typesense** can't rename or swap a collection, so since 0.2.0 an index is an **alias** to a
  collection of its own: `EnsureIndex('products')` creates the collection `products@<n>` and the
  alias `products`. `ReplaceIndex` points the alias to the new index's collection, deletes the
  new index's alias and drops the old collection. Searches never see an empty index.
- **An index made by 0.1.0 on Typesense** is a collection named like the index, without an alias.
  It keeps working. Replacing it drops it first (an alias can't take a collection's name), so
  for a few milliseconds a search answers `ESearchIndexNotFound`. It can't be the source of a
  replace (`ESearchNotSupported`): make the new index with 0.2.0.
- **The mock** moves the data under the target's name, after applying the writes `DeferWrites`
  held.

Another process sees the replaced index within `CacheMs` (60 s by default): that long, it may
check a query against the old schema (Typesense) or the old `MaxHits` (Meilisearch). Every call
still goes to the new index.

## Writes during the rebuild

The live index keeps receiving the outbox's writes while the new one fills; a row changed after
the loop read it reaches only the live index, and the replace would lose it. Two ways out:

- **Stop the outbox's local sink while rebuilding.** The events wait in the outbox; after the
  replace, the sink applies them to the new index, which is now the live one (each reloads the
  current state). Every handler of that sink waits too (an e-mail handler, for instance).
- **Sync again after the replace** the ids changed since the rebuild started (an `UPDATED_AT`
  column, or the events enqueued meanwhile).

## Listing the ids

`ListIds(Filter = nil)` returns every id of an index, or of the documents a filter matches,
**not capped by `MaxHits`**, in no particular order. It holds one string per document in memory.

- In a rebuild in place (keeping the index), it finds the documents whose rows are gone: list
  the index's ids, delete those the database no longer has.
- After a rebuild, comparing counts checks it.
- Meilisearch pages through the documents, 1000 at a time: writes during the listing may make
  it skip or repeat an id. Typesense exports them in one answer.

```pascal
LInIndex := Products.ListIds;
LGone := ... // the ids of LInIndex the database doesn't have
if Length(LGone) > 0 then
  Products.Delete(LGone).WaitFor;
```
