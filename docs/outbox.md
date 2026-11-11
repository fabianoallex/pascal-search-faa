# 7. The outbox bridge

`PascalSearch.Outbox` (package `pascal_search_faa_outbox`, folder `bridges/outbox`) keeps a
search index in step with the database through pascal-db-faa's transactional outbox (its
[`docs/outbox.md`](https://github.com/fabianoallex/pascal-db-faa/blob/main/docs/outbox.md)).
Read that guide first: the relay, the local sink, retries and `dead` deliveries are its.
Decisions: `design.md`, section 11. Sample: [`samples/01-outbox`](../samples/01-outbox/SearchOutbox.dpr).

Without it, a program that commits a product and then writes it to the index loses the index
write when it stops between the two, or when the engine is down. With it, the change and an
event naming the changed ids are one transaction; the bridge writes those ids' **current**
state to the index later, retrying until it gets through.

## The pieces

```pascal
// The change and its event: one transaction.
LScope := LFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  ... // INSERT or UPDATE the product
  TOutbox.Enqueue(LFactory, LQuery, LTenant, 'product.saved',
    SearchOutboxPayload([IntToStr(LId)]), DateTimeToUnix(Now, False));
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

```pascal
// A worker: the bridge is one of the local sink's handlers.
LSink := TOutboxLocalSink.Create(LFactory, PdbOutboxNewOwner('sink'), LOptions);
LSink.AddHandler(TSearchOutboxHandler.Create('search.products',
  LEngine.Index('products'), ['product.saved', 'product.deleted'],
  LCatalog.LoadSearchDocuments));
LRelay := TOutboxRelay.Create(LFactory, LSink, PdbOutboxNewOwner('relay'), LOptions);
// then LRelay.RunOnce(Now) and LSink.RunOnce(Now) on a timer or a worker thread
```

- **The name** (`'search.products'`) is stored by the outbox with each delivery: 1-60
  characters, keep it once deliveries exist.
- **The kinds** are the events this handler takes.
- **The payload** is `{"ids":[...]}` (`SearchOutboxPayload`) or `{"id":...}`, each id a string
  or an integer; other members (a version) are ignored. Keep it thin: ids, not the row. For
  another format, set `IdsReader` to a function that reads the ids from the event.

## The loader decides

```pascal
function TCatalog.LoadSearchDocuments(const AIds: TArray<string>): TSearchDocuments;
```

The loader receives the ids and returns the documents of those that **exist now**; an id with
no document is deleted from the index. So the event's kind doesn't choose between writing and
deleting: a `saved` and a `deleted` handled out of order both end in the database's current
state, and one handler serves both kinds.

- It runs outside any transaction (the local sink runs handlers outside one), and reads what is
  committed.
- A document whose id wasn't asked for, or one returned twice, raises `ESearchArgumentError`.
- It is a method (`of object` on FPC 3.2.2, `reference to` on Delphi: a method compiles on both).

Each event becomes: the ids checked and each taken once, one load, an `Upsert` of the documents
found and a `Delete` of the rest, then **`WaitFor` on both** before the delivery counts as done
(`WaitTimeoutMs`; 0 is the engine's default).

## Failures and retries

Every error is raised, so the local sink tries the delivery again later
(`TOutboxRetry`: 5 s doubling up to 600 s by default) and marks it `dead` after `MaxAttempts`
(10), or at once for a caller's bug (below). A retry loads and writes every id of the event
again: upsert and delete are idempotent, and the load reads the current state. So:

- the engine down (`ESearchUnavailable`), a wait that ran out (`ESearchTimeout`), an index not
  there yet (`ESearchIndexNotFound`): the next try gets through;
- some documents refused (`ESearchWriteFailed`, Typesense) or the whole batch (Meilisearch):
  the next try writes them all again, the good ones included, which does no harm;
- a bad id in a payload or a loader bug (`ESearchArgumentError`), a request the engine refuses
  (`ESearchRequestError`): retrying wouldn't help, so `Handle` raises pascal-db-faa's
  `EOutboxGiveUp` (0.21.0) instead, its message `ESearchArgumentError: ...`, and the delivery is
  **`dead` at the first try** (design S30). `Sync` itself still raises the library's errors.

`OnError` on the sink reports each failed try, a given-up one included.

**An engine down longer than the tries leaves dead deliveries**, and those ids stale in the
index. pascal-db-faa's local sink has one `MaxAttempts` for all its handlers (and one local sink
per database: its claim doesn't filter by handler). With the defaults a delivery is
dead about 30 minutes after its first try, and each try more adds 10 minutes (`MaxAttempts` 15:
about 80 minutes). If outages can be longer, raise it, and resync after one (below).

**Run one sink worker for an index.** Two processes running the same handler at once could
each load a row and write it in the other order, the older state last. One sink handles its
deliveries in sequence, and a retry reloads, so this doesn't happen there.

## A full reindex

A new index, one rebuilt after a schema change (`ESearchSchemaError`), or a resync after dead
deliveries: page through your ids and call `Sync`, the handler's own step. Since 0.2.0 the
better way fills a **new** index beside the live one and replaces it (guide 9): a handler on the
new index, the same loop, then `ReplaceIndex`.

```pascal
LIds := LCatalog.ProductIds;          // or page with SQL, 100 at a time
I := 0;
while I < Length(LIds) do
begin
  ... // LPage := up to 100 ids from I
  LBridge.Sync(LPage);
  Inc(I, Length(LPage));
end;
```

- **Beside the live index, then `ReplaceIndex`** (guide 9): no empty index, no orphan documents.
- **In place** (the index kept): every row is written again; documents whose rows no longer
  exist stay, unless `ListIds` finds them and they are deleted (guide 9).
- **Dropping the index first** (`DropIndex`, `EnsureIndex`) removes them, but searches see an
  index that fills while the loop runs.

Events handled while a reindex runs do no harm: both write current state.

## Testing it

`Handle` takes a `TOutboxEvent`, a record: a unit test builds one and calls the handler on the
mock, no database and no server (`tests/Unit/PascalSearch.OutboxTests.pas`). The whole path,
`Enqueue` to the engine, runs in the integration suite on SQLite
(`tests/Integration/PascalSearch.OutboxIntegrationTests.pas`).
