# Gotchas

Numbered, never renumbered: code and docs cite them by number. Each one says what was measured
and where. The engines' behavior behind the contract is in [`engine-findings.md`](engine-findings.md).

## 1. Computing `0/0` in a test raises `EInvalidOp` on FPC

A test that built NaN with `LZero / LZero` (and infinity with `1 / LZero`) to check that the
library refuses them failed with `EInvalidOp: Invalid floating point operation` on FPC 3.2.2
(Linux), before the library saw the value: FPC leaves FPU exceptions on. Use `Math`'s `NaN` and
`Infinity` constants. (`tests/Unit/PascalSearch.CoreTests.pas`, `NumberText_NaN_Refused`.)

## 2. `JsonFloatToStr` writes an exponent outside 1e-7 .. 1e21

pascal-jsonmapper-faa writes the shortest round-trip text, with `E` notation for large and tiny
numbers (`1E21`, `1.5E-7`). Valid JSON, so fine in a document; but in a filter Meilisearch
answers 0 hits to `price > 1e1` and Typesense matches nothing (finding 24). Filter values go
through `SearchNumberText` (`PascalSearch.Values`), which expands the exponent:
`1000000000000000000000`, `0.00000015`.

## 3. A Typesense filter value can't hold a backtick, and a list changes how `\` reads

Measured on Typesense 30.2 (finding 22). Backticks quote a value with spaces, quotes, `||`, `&&`
and parentheses safely, but nothing escapes a backtick inside one (`` \` ``, a doubled backtick
and `\"` inside double quotes all let the rest of the value through as filter syntax). And
inside `[...]` a backslash escapes, so `` [`C:\doces\`, bebida] `` matched nothing while the same
values joined with `||` matched. The Typesense adapter refuses a value with a backtick
(`ESearchArgumentError`) and never writes a list.

## 4. A `}` inside a `{ }` comment ends it

A unit header quoting JSON (`'{"id":"42"}'`) stopped compiling with "String exceeds line": the
`}` closed the comment and the rest was read as code. Headers that quote braces use `(* ... *)`
(`PascalSearch.Documents`). The same family rule as pascal-db-faa's CLAUDE.md.

## 5. Meilisearch never returns a hit past `maxTotalHits`, and the total doesn't say so

Default 1000 (finding 33): `limit` 5000 gave 1000 hits, page 334 of 3 gave one, while
`totalHits` said 1500. The schema's `MaxHits` sets it, and a page that starts past it raises
`ESearchArgumentError` on every engine instead of coming back empty or short without notice.

## 6. The engines have typo tolerance; the mock doesn't

A contract test expected `mineiro` (only in doc 2's tags, not a Text field) to find nothing. The
mock agreed; Meilisearch found doc 2 through `mineira` in its body, one typo away (finding 47).
A contract test that expects a word not to match uses one no text field comes close to
(`salgado`). (`tests/Unit/PascalSearch.ContractTests.pas`, `Text_OnlyTextFieldsSearched`.)

## 7. Meilisearch facets any filterable field

`Facets(['price'])` on a field declared `[sfFilter, sfSort]` raised on the mock and answered a
distribution on Meilisearch (finding 45): Meilisearch has no "facet only" declaration, a
facet is any filterable attribute. Typesense refuses a field without `facet: true`. Declare
`sfFacet` for every facet; the contract tests a field that is neither, and the mock's
stricter refusal is in `PascalSearch.MockTests` (`Facet_FilterableNotFacet_RequestError`).
