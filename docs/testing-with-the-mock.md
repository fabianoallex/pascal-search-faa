# 6. Testing with the mock

`TMockSearchEngine` (`PascalSearch.Mock`) is the contract in memory: an application's tests run
without a search server. It passes the same contract suite as Meilisearch and Typesense; where
the engines differ, it does the stricter thing (design S23).

```pascal
var
  Engine: IMockSearchEngine;
begin
  Engine := TMockSearchEngine.New;
  Index := Engine.EnsureIndex(Schema);
```

## Test controls

- **`DeferWrites := True`**: a write is applied only when its `WaitFor` runs (with every write
  queued before it), like Meilisearch's tasks. A test then catches code that searches before
  waiting. Off (the default), writes are applied at once.
- **`FailNextWrite(Ids, Message, WholeBatch)`**: the next write refuses those ids (or all of it,
  applying none, with `WholeBatch`); its `WaitFor` raises `ESearchWriteFailed`.
- **`Unavailable := True`**: every call raises `ESearchUnavailable`, as a server down.
- `PendingWrites` (writes queued under `DeferWrites`) and `DocumentCount(IndexName)` for
  assertions.

## What it does, and doesn't

- Text: case and accents folded, every word required, a prefix on the last word, `swRelaxed`
  as on the engines. **No typo tolerance**: a test that expects a word *not* to match should use
  one no text field comes close to, or it passes on the mock and fails on an engine (gotcha 6).
- String equality ignores case but not accents (Meilisearch's behavior; Typesense also folds
  accents).
- It refuses what an engine would: a filter, sort or facet on an undeclared field, a value of
  the wrong kind, an index never ensured.
- `Raw` and `tmEngine` raise `ESearchNotSupported`: code that depends on one engine is tested on
  that engine.
- Synonyms apply (a query word, or a run of words, equal to a group's key also matches through
  its synonyms); highlight marks the query's words and their synonyms' whole, the last word also
  as a prefix, on Text fields only; `ReplaceIndex` first applies what `DeferWrites` held;
  `ListIds` returns the ids in the order they were first added.
- Thread-safe: one lock for the whole engine.

The outbox bridge's own tests (`tests/Unit/PascalSearch.OutboxTests.pas`) show the pattern for
a handler: build the event, call it, assert on the mock.
