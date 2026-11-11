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
- `ListIds(Filter)` lists every id, past `MaxHits` (guide 9).

## Highlight

```pascal
R := Products.Search('café').Highlight(['title', 'body']).Execute;
if R.Hit(0).FindHighlight('title', H) then
  Html := H.ToHtml;            // 'Pão &lt;b&gt; <mark>café</mark>...'
```

- `Highlight([...])` names **Text fields** whose matched words each hit returns, with the
  field's whole value. The mock and Typesense refuse another field (`ESearchRequestError`);
  Meilisearch would highlight it anyway.
- `FindHighlight(Field, H)` is `False` when the field wasn't asked, the text was empty or
  nothing in the field matched.
- `H.Parts` is the value cut where the engine marked a match (`Text`, `Matched`); `H.Text` is
  the plain value. **`H.ToHtml(Pre, Post)` escapes `& < > " '` in every part** and puts the
  matched ones between `Pre` and `Post` (`<mark>` and `</mark>` by default). Neither engine
  escapes HTML (finding 64): the library never hands out the engine's tagged text, so a value
  holding `<script>` can't reach a page unescaped.
- What is marked is the engine's: a prefix marks the matched start (`<mark>Caf</mark>é`), a
  typo or a folded accent the whole word. The mock marks whole words and the prefix of the last
  word, and has no typos.
- The field doesn't have to be among `Fields([...])`. Cropping to a snippet differs between the
  engines (finding 65): native access.

## Synonyms

```pascal
Products.SetSynonyms([
  TSearchSynonym.Equivalent(['tv', 'televisão']),             // each finds the others
  TSearchSynonym.OneWay('geladeira', ['refrigerador']),       // geladeira finds refrigerador, not back
  TSearchSynonym.Equivalent(['café preto', 'expresso'])]);    // several words
```

- `SetSynonyms` **replaces** every group of the index (`[]` clears them) and returns once the
  engine applies them to searches; no reindex. Case and accents don't matter.
- Checked at the call (`ESearchArgumentError`): no blank word, two words or more in an
  equivalent group, one or more after a one-way root.
- Meilisearch keeps them in the index's `synonyms` setting; Typesense in a synonym set named
  like the index's collection, attached to it and deleted with it (an application's own sets
  attached to the collection are kept). The mock applies them too.
- They belong to the index: a rebuilt index needs them set before `ReplaceIndex` (guide 9).

## Native access

What the contract leaves out (cropping, scores, geo, `EXISTS`...) goes through the adapter:

- `(Engine as IMeilisearchEngine).Send(Method, Path, Body)` and `WaitForTask`;
  `(Engine as ITypesenseEngine).Send(...)`: any endpoint, with the key and the error mapping;
- typed settings, each returning once applied: Meilisearch `SetTypoTolerance(Index,
  TMeilisearchTypoTolerance)` (`Standard` is the engine's own), `SetRankingRules(Index, [...])`,
  `SetStopWords(Index, [...])`; Typesense `SetCuration(Index, [TTypesenseCuration.Create(Id,
  Query, PinnedIds, HiddenIds)])` (a curation set named like the collection). Typesense's typo
  settings are search parameters: `Raw('num_typos', '0')`;
- `.Raw('name', JsonValueText)` adds an engine parameter to a query, and `R.RawJson` is the
  engine's answer as received. The mock refuses `Raw` (`ESearchNotSupported`), so a test
  notices code that depends on one engine.
