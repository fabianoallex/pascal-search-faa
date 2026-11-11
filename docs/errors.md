# 5. Errors

One base class, `ESearchError`, and subclasses chosen by what the caller does next (design
S21). All carry `HttpStatus`, `EngineCode` (Meilisearch's `code`; empty on Typesense, which
sends a message only) and `EngineMessage`.

| Class | When | Next step |
|---|---|---|
| `ESearchUnavailable` | no answer (connection, timeout), a 5xx | retry later; an API answers 503. A write is not sent again by the library (guide 3) |
| `ESearchAuthError` | 401, 403 | fix the configuration |
| `ESearchIndexNotFound` | the index doesn't exist | `EnsureIndex` |
| `ESearchRequestError` | any other 4xx: a field not declared for a filter, sort or facet, a bad value | a bug in the caller |
| `ESearchWriteFailed` | `WaitFor` found refused documents (`Failures`, `WholeBatch`) | fix or skip them |
| `ESearchTimeout` | `WaitFor`'s limit reached, the write still pending | wait again, or alert |
| `ESearchSchemaError` | `EnsureIndex` can't change the index in place (a field's kind) | drop and rebuild the index |
| `ESearchArgumentError` | refused at the call: an id, an index or field name, a backtick on Typesense, a page size, NaN | a bug in the caller |
| `ESearchNotSupported` | the mock, for `Raw` and `tmEngine`; `ReplaceIndex` from a Typesense collection made by 0.1.0 | run that test on an engine; make the new index with 0.2.0 |

- `Get` of a missing document returns nil, not an exception.
- Deleting a missing id, or dropping a missing index, is not an error.
- Typesense answers 404 both for a missing collection and for a missing field; the adapter
  tells them apart by the message, the only signal it gives.
- The outbox bridge's `Handle` turns `ESearchArgumentError` and `ESearchRequestError` into
  pascal-db-faa's `EOutboxGiveUp`: the delivery is dead at once (guide 7).
