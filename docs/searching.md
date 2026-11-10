# 4. Searching

```pascal
R := Products.Search('café preto')
  .Where(F.All([
    F.Eq('category', 'bebida'),
    F.Between('price', 5, 8),                  // inclusive
    F.Any([F.Eq('available', True), F.Gt('stock', 0)]),
    F.NoneOf('tags', ['gelada'])]))
  .OrderBy('price', soAsc).ThenBy('created_at', soDesc)
  .Page(1, 20)
  .Facets(['category', 'tags'])
  .Fields(['id', 'title'])
  .Execute;

for I := 0 to R.Count - 1 do
  Writeln(R.Hit(I).Id, ' ', R.Hit(I).Document.Find('title').AsString);
```

`R.Hit(I).Document` is a pascal-jsonmapper-faa `TJsonValue` owned by the result: don't free
it. No manual free anywhere in the contract.

## The text

- **Words, by default** (`tmWords`): a leading `-` and every `"` are removed before sending,
  because both engines read them as "without" and "a phrase". `TextMode(tmEngine)` sends the
  text as typed, with the engine's own syntax.
- **Every word is required, by default** (`swAll`). Both engines' own default drops words until
  something matches, which makes "café x" find every coffee. `Words(swRelaxed)` gives that back.
- Case and accents are folded and the last word is also a prefix, on both engines.
- `''` matches every document. Only the schema's `Text` fields are searched.
- Typo tolerance is each engine's own (guide 8). The mock has none.

## Filters

**A filter is a tree, never text**: there is no API that takes filter text, so a user's input
can't change a filter's meaning. `F` is `TSearchFilters`:

- comparisons: `Eq`, `NotEq`, `AnyOf` (in), `NoneOf` (not in), `Gt`, `Ge`, `Lt`, `Le`,
  `Between`; combinators: `All` (and), `Any` (or);
- values: string, Int64, Double, Boolean, instant (a UTC `TDateTime`);
- on an array field, `Eq` and `AnyOf` match a document whose array holds the value;
- `NotEq` and `NoneOf` keep documents without the field.

Left out on purpose: negating a group, `Exists`/`IsNull`, prefix and contains (the engines
disagree, design S12). String equality is case-insensitive; accents depend on the engine
(guide 8). On Typesense a filter string holding a backtick raises `ESearchArgumentError`
(gotcha 3).

## Sort, paging, facets, fields

- **No sort means the engine's relevance**: with text, by relevance; without, the order is
  unspecified and differs between engines. Documents without the sort field come last in both
  directions. Typesense takes at most 3 sort keys.
- **`Page(Page, PageSize)`**: 1-based, 1-250 per page, an exact `R.Total`. `PageSize` 0 gives
  the total and the facets only. A page past the schema's `MaxHits` raises
  `ESearchArgumentError`.
- **Facets**: `R.FindFacet('category', LFacet)`; `LFacet.Values[J].Value` and `.Count`, ordered
  by count, then value. The engines return up to 100 values per facet.
- **Fields**: `Fields([...])` limits what comes back; empty means every stored field. The id
  always comes back.
- `Get(Id)` returns the hit or nil; `GetMany(Ids)` the ones found, in the order asked.

## Native access

What the contract leaves out (synonyms, typo settings, ranking rules, highlight, geo...) goes
through the adapter:

- `(Engine as IMeilisearchEngine).Send(Method, Path, Body)` and `WaitForTask`;
  `(Engine as ITypesenseEngine).Send(...)`: any endpoint, with the key and the error mapping;
- `.Raw('name', JsonValueText)` adds an engine parameter to a query, and `R.RawJson` is the
  engine's answer as received. The mock refuses `Raw` (`ESearchNotSupported`), so a test
  notices code that depends on one engine.
