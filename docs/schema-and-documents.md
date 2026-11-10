# 2. Schema and documents

## Declaring an index

Every index has a declared schema, on both engines: it is what makes them behave the same
(design S3).

```pascal
Products := Engine.EnsureIndex(TSearchSchema.New('products')
  .Text('title').Text('body')                 // searched by the text, in this order
  .Keyword('category', [sfFilter, sfFacet])   // a string, compared whole
  .Keywords('tags', [sfFilter, sfFacet])      // an array of strings
  .Num('price', [sfFilter, sfSort])           // Double
  .Int('stock', [sfFilter, sfSort])           // Int64
  .Bool('available', [sfFilter])
  .Instant('created_at', [sfFilter, sfSort])  // a UTC TDateTime, stored as Unix ms
  .Stored('image_url'));                      // returned, never searched or filtered
```

- Only `Text` fields are searched by the text, in the order declared.
- Filter, sort and facet only on fields declared with that flag: anything else raises
  `ESearchRequestError` on every engine. **Declare `sfFacet` for every facet** (Meilisearch would
  facet any filterable field, Typesense wouldn't; gotcha 7).
- Every field is optional: a document may leave it out.
- `WithMaxHits(N)` (default 1000): the deepest hit a search can reach. A page starting past it
  raises `ESearchArgumentError` instead of coming back empty (Meilisearch's `maxTotalHits`,
  gotcha 5).

`EnsureIndex` creates the index or brings an existing one up to the schema (new fields, changed
flags), and returns when the index is ready. A change it can't make in place, a field's kind,
raises `ESearchSchemaError`: drop the index (`DropIndex`) and rebuild it (guide 7 shows a
reindex). Call it at startup; `Engine.Index(Name)` gives the index without a request.

Names: an index `[A-Za-z0-9_-]`, 1-64 characters; a field `[A-Za-z_][A-Za-z0-9_]*`. Checked at
the call (`ESearchArgumentError`).

## Documents and ids

```pascal
Doc := TSearchDocument.New('42')
  .Str('title', 'Café com leite')
  .Strs('tags', ['quente', 'café'])
  .Num('price', 7.5).Int('stock', 3).Bool('available', True)
  .Instant('created_at', LUtc);
Doc := TSearchDocument.FromObject('42', LProductDto);   // published properties (TJsonMapper)
Doc := TSearchDocument.FromJson(LJson);                 // an object with an "id"
```

- **An id is `[A-Za-z0-9_-]`, 1-511 bytes**, checked at once: what both engines accept. A
  database integer becomes its decimal text (`IntToStr`).
- An upsert **replaces** the whole document; there is no partial update.

## Values

- **Instants are UTC** `TDateTime`s, stored as Unix milliseconds (`SearchInstantToMs`). Neither
  engine compares date text.
- **Numbers** go into filters in plain decimal, never with an exponent (`SearchNumberText`):
  both engines misread `1e1` in a filter (gotcha 2). NaN and infinity are refused at the call.
- **Keep codes ASCII** in keyword fields you filter by equality: Typesense folds accents in
  `Eq`, Meilisearch doesn't (guide 8).
