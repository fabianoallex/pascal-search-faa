# 3. Writing and waiting

```pascal
Products.Upsert([Doc1, Doc2]).WaitFor;
Products.Delete(['7', '8']).WaitFor;                 // a missing id is not an error
Products.DeleteWhere(F.Eq('category', 'old')).WaitFor;
```

## Wait before you search

**Every write returns an `ISearchWrite`, and waiting is explicit** (design S6). Meilisearch
queues a task and applies it later: a search right after `Upsert` may not see it. `WaitFor`
returns once the write is searchable; on Typesense, which applies writes before answering, it
returns at once. Write code that waits, and it works on both.

- `WaitFor(0)` waits up to the engine's configured limit (Meilisearch `WaitTimeoutMs`, 30 s by
  default); `WaitFor(N)` up to N ms. Past it: `ESearchTimeout`, the write still pending (wait
  again, or alert).
- `Pending` asks the engine whether the write is still waiting.
- Send several writes, then wait for each: Meilisearch runs the tasks meanwhile.

## Refused documents

**`WaitFor` is where a refused write is raised**, on every engine: `ESearchWriteFailed`, with
`Failures` (`Id`, `Code`, `Message` per document) and `WholeBatch`.

- Meilisearch: a task is all or nothing. Every id of the batch is listed and `WholeBatch` is
  `True`.
- Typesense: the good documents of an import are kept, the refused ones are listed;
  `WholeBatch` only when all were refused.

A caller that doesn't wait never learns about a refused document on Meilisearch.

## A write that got no answer

The connection dropped, the server timed out: `ESearchUnavailable`, and **the library doesn't
send the write again**. Writes are POSTs, which pascal-common-faa's transport never repeats; the
engine may or may not have queued it, and a second send would be a second task. Upsert and
delete are idempotent, so the caller sends them again, or lets the outbox do it (guide 7).

## Notes

- An index never ensured raises `ESearchIndexNotFound` on a write. (Meilisearch would create it
  without a schema; its adapter checks the index first, one extra request on a kept-alive
  connection.)
- An empty `Upsert([])` or `Delete([])` sends nothing, and its `WaitFor` returns at once.
- Typesense deletes by `filter_by=id:[...]` in chunks of 100 ids.
