unit PascalSearch.ContractTests;

{ The contract every engine keeps (docs/design.md, S24). The unit suite runs
  it on the mock; an integration runner points PascalSearch.ContractEnv at
  Meilisearch or Typesense and runs the same bodies.

  Each test gets a fresh index with the engine probe's seven documents
  (accents, a category with quotes, one with backslashes, one with an
  apostrophe and a comma, one without category/price/stock/available, one
  with available null). Without a sort the order of matches is not part of
  the contract, so those tests compare sorted ids. What the engines do
  differently (typos, accents in equality, relevance order) is not tested
  here.

  0.2.0 (design, section 12): ReplaceIndex with a second index
  (contract_products_new), ListIds, Highlight in parts, SetSynonyms. Words
  that synonyms add are picked so that no text field comes close to them
  (gotcha 6).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.ContractEnv;

type
  [TestFixture]
  TContractTests = class
  private
    FEngine: ISearchEngine;
    FIndex: ISearchIndex;
    function Find(const AText: string): string;
    function Where(const AFilter: ISearchFilter): string;
    function Sorted(const AQuery: ISearchQuery): string;
    function HitById(const AResult: ISearchResult; const AId: string): ISearchHit;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Text_AccentsAndCase_Folded;
    [Test] procedure Text_EveryWordRequired;
    [Test] procedure Text_LastWordIsAPrefix;
    [Test] procedure Text_Empty_MatchesAll;
    [Test] procedure Text_WordsMode_IgnoresOperators;
    [Test] procedure Text_Relaxed_DropsWordsWhenNoneMatchAll;
    [Test] procedure Text_OnlyTextFieldsSearched;
    [Test] procedure Text_HostileInput_NoError;

    [Test] procedure Filter_Eq_IgnoresCase;
    [Test] procedure Filter_ValuesWithSyntax_AreLiteral;
    [Test] procedure Filter_NotEq_IncludesMissing;
    [Test] procedure Filter_AnyOf_NoneOf;
    [Test] procedure Filter_Numbers;
    [Test] procedure Filter_Booleans;
    [Test] procedure Filter_Instants;
    [Test] procedure Filter_Arrays;
    [Test] procedure Filter_Groups;
    [Test] procedure Filter_Id;
    [Test] procedure Filter_WithText;
    [Test] procedure Filter_UndeclaredField_RequestError;

    [Test] procedure Sort_MissingLast_BothDirections;
    [Test] procedure Sort_SeveralKeys;
    [Test] procedure Sort_Instant;
    [Test] procedure Sort_UndeclaredField_RequestError;

    [Test] procedure Page_SlicesAndTotal;
    [Test] procedure Page_SizeZero_TotalOnly;
    [Test] procedure Page_MaxHits;

    [Test] procedure Facets_CountsInContractOrder;
    [Test] procedure Facets_FollowTextAndFilter;
    [Test] procedure Facets_UndeclaredField_RequestError;

    [Test] procedure Fields_OnlyThoseAsked;
    [Test] procedure Get_RoundTrip;
    [Test] procedure GetMany_InOrderAsked;

    [Test] procedure Upsert_ReplacesWholeDocument;
    [Test] procedure Delete_MissingId_NoError;
    [Test] procedure DeleteWhere_RemovesMatches;
    [Test] procedure EnsureIndex_Again_KeepsDocuments;
    [Test] procedure Index_NeverEnsured_NotFound;
    [Test] procedure DropIndex_Missing_NoError;

    [Test] procedure ReplaceIndex_ExistingTarget;
    [Test] procedure ReplaceIndex_MissingTarget_Renames;
    [Test] procedure ReplaceIndex_Twice_SameSourceName;
    [Test] procedure ReplaceIndex_MissingSource_NotFound;
    [Test] procedure ListIds_AllAndFiltered;
    [Test] procedure ListIds_PastMaxHits;
    [Test] procedure Highlight_MatchedWords;
    [Test] procedure Highlight_PrefixAndAccents;
    [Test] procedure Highlight_HtmlEscaped;
    [Test] procedure Highlight_NoText_OrFieldNotReturned;
    [Test] procedure Synonyms_EquivalentAndOneWay;
    [Test] procedure Synonyms_SeveralWords;
    [Test] procedure Synonyms_ReplacedAndCleared;
  end;

implementation

const
  INDEX_NAME = 'contract_products';
  STAGING_NAME = 'contract_products_new';

function NewSchema: ISearchSchema;
begin
  Result := TSearchSchema.New(INDEX_NAME)
    .Text('title')
    .Text('body')
    .Keyword('category', [sfFilter, sfFacet])
    .Keywords('tags', [sfFilter, sfFacet])
    .Num('price', [sfFilter, sfSort])
    .Int('stock', [sfFilter, sfSort])
    .Bool('available', [sfFilter, sfFacet])
    .Instant('created_at', [sfFilter, sfSort])
    .Stored('note');
end;

function Day(ADay: Integer): TDateTime;
begin
  Result := EncodeDate(2026, 1, ADay);
end;

function SeedDocs: TSearchDocuments;
begin
  Result := nil;
  SetLength(Result, 7);
  Result[0] := TSearchDocument.New('1').Str('title', 'Café com leite')
    .Str('body', 'Bebida quente servida no café da manhã').Num('price', 7.5)
    .Int('stock', 10).Str('category', 'bebida').Strs('tags', ['quente', 'café'])
    .Bool('available', True).Instant('created_at', Day(1)).Str('note', 'n1');
  Result[1] := TSearchDocument.New('2').Str('title', 'Pão de queijo')
    .Str('body', 'Receita mineira com polvilho').Num('price', 6)
    .Int('stock', 0).Str('category', 'salgado').Strs('tags', ['mineiro'])
    .Bool('available', True).Instant('created_at', Day(2));
  Result[2] := TSearchDocument.New('3').Str('title', 'Café preto')
    .Str('body', 'Sem açúcar, forte, 50% arábica').Num('price', 5)
    .Int('stock', 5).Str('category', 'bebida').Strs('tags', ['quente', 'café'])
    .Bool('available', False).Instant('created_at', Day(3));
  Result[3] := TSearchDocument.New('4').Str('title', 'Água de coco')
    .Str('body', 'Bebida gelada, um copo d''água').Num('price', 8.25)
    .Int('stock', 2).Str('category', 'Bar "Zé"').Strs('tags', ['gelada'])
    .Bool('available', True).Instant('created_at', Day(4));
  Result[4] := TSearchDocument.New('5').Str('title', 'Pé de moleque')
    .Str('body', 'Doce de amendoim com rapadura').Num('price', 3)
    .Int('stock', 0).Str('category', 'C:\doces\').Strs('tags', ['doce'])
    .Null('available').Instant('created_at', Day(5));
  Result[5] := TSearchDocument.New('6').Str('title', 'Bolo de fubá')
    .Str('body', 'Sem categoria nem preço').Strs('tags', [])
    .Instant('created_at', Day(6));
  Result[6] := TSearchDocument.New('7').Str('title', 'Quindim')
    .Str('body', 'Doce amarelo').Num('price', 4)
    .Int('stock', 1).Str('category', 'x''y, w').Strs('tags', ['doce'])
    .Bool('available', True).Instant('created_at', Day(7));
end;

// The ids of the hits, in order, joined by commas.
function Ids(const AHits: ISearchHits): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AHits.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + AHits.Hit(I).Id;
  end;
end;

// AIds sorted and joined by commas.
function SortedText(const AIds: TArray<string>): string;
var
  L: TArray<string>;
  I, J: Integer;
  T: string;
begin
  L := Copy(AIds, 0, Length(AIds));
  for I := 1 to High(L) do
  begin
    T := L[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(L[J], T) > 0) do
    begin
      L[J + 1] := L[J];
      Dec(J);
    end;
    L[J + 1] := T;
  end;
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + L[I];
  end;
end;

// The same, sorted: for results whose order the contract doesn't fix.
function SortedIds(const AHits: ISearchHits): string;
var
  L: TArray<string>;
  I, J: Integer;
  T: string;
begin
  L := nil;
  SetLength(L, AHits.Count);
  for I := 0 to AHits.Count - 1 do
    L[I] := AHits.Hit(I).Id;
  for I := 1 to High(L) do
  begin
    T := L[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(L[J], T) > 0) do
    begin
      L[J + 1] := L[J];
      Dec(J);
    end;
    L[J + 1] := T;
  end;
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + L[I];
  end;
end;

function FacetText(const AResult: ISearchResult; const AField: string): string;
var
  LFacet: TSearchFacet;
  I: Integer;
begin
  if not AResult.FindFacet(AField, LFacet) then
    Exit('(no facet)');
  Result := '';
  for I := 0 to High(LFacet.Values) do
  begin
    if I > 0 then
      Result := Result + '|';
    Result := Result + LFacet.Values[I].Value + '=' + IntToStr(LFacet.Values[I].Count);
  end;
end;

{ TContractTests }

procedure TContractTests.Setup;
begin
  FEngine := ContractEngine;
  FEngine.DropIndex(INDEX_NAME);
  FIndex := FEngine.EnsureIndex(NewSchema);
  FIndex.Upsert(SeedDocs).WaitFor(ContractWait);
end;

procedure TContractTests.TearDown;
begin
  try
    if FEngine <> nil then
    begin
      FEngine.DropIndex(STAGING_NAME);
      FEngine.DropIndex(INDEX_NAME);
    end;
  except
    // An engine that went away: the next Setup drops the index again.
  end;
  FIndex := nil;
  FEngine := nil;
end;

function TContractTests.Sorted(const AQuery: ISearchQuery): string;
begin
  Result := SortedIds(AQuery.Page(1, 50).Execute);
end;

function TContractTests.Find(const AText: string): string;
begin
  Result := Sorted(FIndex.Search(AText));
end;

function TContractTests.Where(const AFilter: ISearchFilter): string;
begin
  Result := Sorted(FIndex.Search('').Where(AFilter));
end;

procedure TContractTests.Text_AccentsAndCase_Folded;
begin
  TAssert.AssertEquals('café', '1,3', Find('café'));
  TAssert.AssertEquals('cafe', '1,3', Find('cafe'));
  TAssert.AssertEquals('CAFÉ', '1,3', Find('CAFÉ'));
  TAssert.AssertEquals('agua', '4', Find('agua'));
  TAssert.AssertEquals('ÁGUA', '4', Find('ÁGUA'));
  TAssert.AssertEquals('fuba', '6', Find('fuba'));
end;

procedure TContractTests.Text_EveryWordRequired;
begin
  TAssert.AssertEquals('café preto', '3', Find('café preto'));
  TAssert.AssertEquals('preto café', '3', Find('preto café'));
  TAssert.AssertEquals('café x', '', Find('café x'));
  TAssert.AssertEquals('pão de queijo', '2', Find('pão de queijo'));
end;

procedure TContractTests.Text_LastWordIsAPrefix;
begin
  TAssert.AssertEquals('caf', '1,3', Find('caf'));
  TAssert.AssertEquals('pre (preto, preço)', '3,6', Find('pre'));
  TAssert.AssertEquals('leite caf', '1', Find('leite caf'));
  TAssert.AssertEquals('polvi', '2', Find('polvi'));
end;

procedure TContractTests.Text_Empty_MatchesAll;
begin
  TAssert.AssertEquals('1,2,3,4,5,6,7', Find(''));
  TAssert.AssertEquals('1,2,3,4,5,6,7', Find('   '));
  TAssert.AssertEquals(Int64(7), FIndex.Search('').Execute.Total);
end;

procedure TContractTests.Text_WordsMode_IgnoresOperators;
begin
  // Both engines read "-word" as "without word" and quotes as a phrase;
  // tmWords (the default) removes them before sending.
  TAssert.AssertEquals('-café', '1,3', Find('-café'));
  TAssert.AssertEquals('"café', '1,3', Find('"café'));
  TAssert.AssertEquals('"café preto"', '3', Find('"café preto"'));
  TAssert.AssertEquals('café -preto', '3', Find('café -preto'));
end;

procedure TContractTests.Text_Relaxed_DropsWordsWhenNoneMatchAll;
begin
  // Only the case where every word fails: when some documents match them all,
  // Meilisearch still adds those matching fewer and Typesense doesn't.
  TAssert.AssertEquals('1,3', Sorted(FIndex.Search('café x').Words(swRelaxed)));
end;

procedure TContractTests.Text_OnlyTextFieldsSearched;
begin
  // Doc 3's category is "bebida", but only title and body are Text fields.
  TAssert.AssertEquals('1,4', Find('bebida'));
  // Doc 2's category, a word close to nothing in a Text field (the engines'
  // typo tolerance would find "mineiro" in "mineira").
  TAssert.AssertEquals('', Find('salgado'));
end;

procedure TContractTests.Text_HostileInput_NoError;
const
  INPUTS: array[0..10] of string = ('café)', '*', '+', 'NEAR(café preto)', 'a & b',
    '50%', 'd''água', 'café:*', 'café OR leite', '\', '`');
var
  I: Integer;
begin
  for I := 0 to High(INPUTS) do
    FIndex.Search(INPUTS[I]).Execute;
  TAssert.AssertTrue(True);
end;

procedure TContractTests.Filter_Eq_IgnoresCase;
begin
  TAssert.AssertEquals('1,3', Where(F.Eq('category', 'bebida')));
  TAssert.AssertEquals('1,3', Where(F.Eq('category', 'BEBIDA')));
  TAssert.AssertEquals('', Where(F.Eq('category', 'beb')));
end;

procedure TContractTests.Filter_ValuesWithSyntax_AreLiteral;
begin
  TAssert.AssertEquals('quotes', '4', Where(F.Eq('category', 'Bar "Zé"')));
  TAssert.AssertEquals('backslashes', '5', Where(F.Eq('category', 'C:\doces\')));
  TAssert.AssertEquals('apostrophe, comma', '7', Where(F.Eq('category', 'x''y, w')));
  TAssert.AssertEquals('Meilisearch injection', '',
    Where(F.Eq('category', 'x" OR price > 0 OR category = "y')));
  TAssert.AssertEquals('Meilisearch injection, single quotes', '',
    Where(F.Eq('category', 'x'' OR price > 0 OR category = ''y')));
  TAssert.AssertEquals('Typesense injection', '',
    Where(F.Eq('category', 'bebida || price:>0')));
  TAssert.AssertEquals('unquoted value', '', Where(F.Eq('category', 'bebida OR price > 0')));
  TAssert.AssertEquals('AnyOf with both', '4,5', Where(F.AnyOf('category', ['C:\doces\', 'Bar "Zé"'])));
  TAssert.AssertEquals('NoneOf with both', '1,2,3,6,7',
    Where(F.NoneOf('category', ['C:\doces\', 'Bar "Zé"'])));
  TAssert.AssertEquals('then another condition', '5',
    Where(F.All([F.Eq('category', 'C:\doces\'), F.Gt('price', 0)])));
end;

procedure TContractTests.Filter_NotEq_IncludesMissing;
begin
  // Doc 6 has no category.
  TAssert.AssertEquals('2,4,5,6,7', Where(F.NotEq('category', 'bebida')));
end;

procedure TContractTests.Filter_AnyOf_NoneOf;
begin
  TAssert.AssertEquals('1,2,3', Where(F.AnyOf('category', ['bebida', 'salgado'])));
  TAssert.AssertEquals('4,5,6,7', Where(F.NoneOf('category', ['bebida', 'salgado'])));
  TAssert.AssertEquals('1,2,5', Where(F.AnyOf('stock', [10, 0, 99])));
  TAssert.AssertEquals('', Where(F.AnyOf('stock', [99])));
end;

procedure TContractTests.Filter_Numbers;
begin
  TAssert.AssertEquals('gt', '1,2,4', Where(F.Gt('price', 5)));
  TAssert.AssertEquals('ge', '1,2,3,4', Where(F.Ge('price', 5)));
  TAssert.AssertEquals('lt', '5,7', Where(F.Lt('price', 5)));
  TAssert.AssertEquals('le', '3,5,7', Where(F.Le('price', 5)));
  TAssert.AssertEquals('between', '1,2,3', Where(F.Between('price', 5, 8)));
  TAssert.AssertEquals('between reals', '1,2,3', Where(F.Between('price', 4.5, 7.5)));
  TAssert.AssertEquals('eq real', '1', Where(F.Eq('price', 7.5)));
  TAssert.AssertEquals('eq integer on a real field', '2', Where(F.Eq('price', 6)));
  TAssert.AssertEquals('eq integer', '2,5', Where(F.Eq('stock', 0)));
  TAssert.AssertEquals('gt integer', '1,3,4,7', Where(F.Gt('stock', 0)));
  TAssert.AssertEquals('negative', '1,2,3,4,5,7', Where(F.Gt('price', -1)));
  TAssert.AssertEquals('large', '', Where(F.Gt('price', 1e21)));
  TAssert.AssertEquals('tiny', '1,2,3,4,5,7', Where(F.Gt('price', 1.5e-7)));
end;

procedure TContractTests.Filter_Booleans;
begin
  TAssert.AssertEquals('1,2,4,7', Where(F.Eq('available', True)));
  TAssert.AssertEquals('3', Where(F.Eq('available', False)));
end;

procedure TContractTests.Filter_Instants;
begin
  TAssert.AssertEquals('4,5,6,7', Where(F.Ge('created_at', F.At(Day(4)))));
  TAssert.AssertEquals('2,3', Where(F.Between('created_at', F.At(Day(2)), F.At(Day(3)))));
  TAssert.AssertEquals('1', Where(F.Eq('created_at', F.At(Day(1)))));
  TAssert.AssertEquals('1', Where(F.Lt('created_at', F.At(Day(1) + EncodeTime(0, 0, 0, 1)))));
end;

procedure TContractTests.Filter_Arrays;
begin
  TAssert.AssertEquals('1,3', Where(F.Eq('tags', 'café')));
  TAssert.AssertEquals('4,5,7', Where(F.AnyOf('tags', ['doce', 'gelada'])));
  TAssert.AssertEquals('2,4,5,6,7', Where(F.NoneOf('tags', ['quente'])));
end;

procedure TContractTests.Filter_Groups;
begin
  TAssert.AssertEquals('1,2', Where(F.All([
    F.Any([F.Eq('category', 'bebida'), F.Eq('category', 'salgado')]),
    F.NotEq('available', False)])));
  TAssert.AssertEquals('2,5,7', Where(F.Any([
    F.Eq('stock', 0),
    F.All([F.Eq('tags', 'doce'), F.Gt('price', 3.5)])])));
end;

procedure TContractTests.Filter_Id;
begin
  TAssert.AssertEquals('3', Where(F.Eq('id', '3')));
  TAssert.AssertEquals('1,7', Where(F.AnyOf('id', ['1', '7', 'nope'])));
  TAssert.AssertEquals('1,2,4,5,6,7', Where(F.NotEq('id', '3')));
end;

procedure TContractTests.Filter_WithText;
begin
  TAssert.AssertEquals('1', Sorted(FIndex.Search('café').Where(F.Eq('available', True))));
end;

procedure TContractTests.Filter_UndeclaredField_RequestError;
begin
  try
    FIndex.Search('').Where(F.Eq('body', 'x')).Execute;
    TAssert.Fail('A filter on a field not declared filterable must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('body', E.Message + E.EngineMessage) > 0);
  end;
end;

procedure TContractTests.Sort_MissingLast_BothDirections;
begin
  TAssert.AssertEquals('asc', '5,7,3,2,1,4,6',
    Ids(FIndex.Search('').OrderBy('price').Page(1, 50).Execute));
  TAssert.AssertEquals('desc', '4,1,2,3,7,5,6',
    Ids(FIndex.Search('').OrderBy('price', soDesc).Page(1, 50).Execute));
end;

procedure TContractTests.Sort_SeveralKeys;
begin
  // stock desc: 10(1), 5(3), 2(4), 1(7), then 0 for 2 and 5 by price asc
  // (5 is 3, 2 is 6); doc 6 has no stock.
  TAssert.AssertEquals('1,3,4,7,5,2,6', Ids(FIndex.Search('').OrderBy('stock', soDesc)
    .ThenBy('price').Page(1, 50).Execute));
end;

procedure TContractTests.Sort_Instant;
begin
  TAssert.AssertEquals('7,6,5,4,3,2,1',
    Ids(FIndex.Search('').OrderBy('created_at', soDesc).Page(1, 50).Execute));
  TAssert.AssertEquals('3,1', Ids(FIndex.Search('café').OrderBy('created_at', soDesc).Execute));
end;

procedure TContractTests.Sort_UndeclaredField_RequestError;
begin
  try
    FIndex.Search('').OrderBy('title').Execute;
    TAssert.Fail('Sorting by a field not declared sortable must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('title', E.Message + E.EngineMessage) > 0);
  end;
end;

procedure TContractTests.Page_SlicesAndTotal;
var
  R: ISearchResult;
begin
  R := FIndex.Search('').OrderBy('price').Page(1, 3).Execute;
  TAssert.AssertEquals('5,7,3', Ids(R));
  TAssert.AssertEquals(Int64(7), R.Total);
  TAssert.AssertEquals(1, R.Page);
  TAssert.AssertEquals(3, R.PageSize);
  R := FIndex.Search('').OrderBy('price').Page(3, 3).Execute;
  TAssert.AssertEquals('6', Ids(R));
  R := FIndex.Search('').OrderBy('price').Page(4, 3).Execute;
  TAssert.AssertEquals('', Ids(R));
  TAssert.AssertEquals(Int64(7), R.Total);
end;

procedure TContractTests.Page_SizeZero_TotalOnly;
var
  R: ISearchResult;
begin
  R := FIndex.Search('café').Page(1, 0).Execute;
  TAssert.AssertEquals(0, R.Count);
  TAssert.AssertEquals(Int64(2), R.Total);
end;

procedure TContractTests.Page_MaxHits;
var
  R: ISearchResult;
begin
  FIndex := FEngine.EnsureIndex(NewSchema.WithMaxHits(5));
  // Positions 3 and 4 only: nothing past the fifth hit.
  R := FIndex.Search('').OrderBy('price').Page(2, 3).Execute;
  TAssert.AssertEquals('2,1', Ids(R));
  TAssert.AssertEquals(Int64(7), R.Total);
  try
    FIndex.Search('').Page(2, 5).Execute;
    TAssert.Fail('A page that starts past MaxHits must raise');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('MaxHits', E.Message) > 0);
  end;
end;

procedure TContractTests.Facets_CountsInContractOrder;
var
  R: ISearchResult;
begin
  R := FIndex.Search('').Facets(['category', 'available']).Page(1, 0).Execute;
  TAssert.AssertEquals('bebida=2|Bar "Zé"=1|C:\doces\=1|salgado=1|x''y, w=1',
    FacetText(R, 'category'));
  TAssert.AssertEquals('true=4|false=1', FacetText(R, 'available'));
  TAssert.AssertEquals(2, R.FacetCount);
end;

procedure TContractTests.Facets_FollowTextAndFilter;
var
  R: ISearchResult;
begin
  R := FIndex.Search('café').Facets(['tags', 'category']).Execute;
  TAssert.AssertEquals('café=2|quente=2', FacetText(R, 'tags'));
  TAssert.AssertEquals('bebida=2', FacetText(R, 'category'));
  R := FIndex.Search('').Where(F.Gt('price', 4)).Facets(['category']).Execute;
  TAssert.AssertEquals('bebida=2|Bar "Zé"=1|salgado=1', FacetText(R, 'category'));
end;

procedure TContractTests.Facets_UndeclaredField_RequestError;
begin
  // A field neither filterable nor a facet. (A filterable field that isn't
  // a facet: Meilisearch answers it, Typesense and the mock refuse it.)
  try
    FIndex.Search('').Facets(['note']).Execute;
    TAssert.Fail('A facet on a field not declared as one must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('note', E.Message + E.EngineMessage) > 0);
  end;
end;

procedure TContractTests.Fields_OnlyThoseAsked;
var
  R: ISearchResult;
  D: TJsonValue;
begin
  R := FIndex.Search('').Where(F.Eq('id', '1')).Fields(['title', 'note']).Execute;
  TAssert.AssertEquals(1, R.Count);
  D := R.Hit(0).Document;
  TAssert.AssertEquals('1', D.Find('id').AsString);
  TAssert.AssertEquals('Café com leite', D.Find('title').AsString);
  TAssert.AssertEquals('a Stored field comes back', 'n1', D.Find('note').AsString);
  TAssert.AssertTrue('body not asked', D.Find('body') = nil);
  R := FIndex.Search('').Where(F.Eq('id', '1')).Fields(['id']).Execute;
  TAssert.AssertEquals('1', R.Hit(0).Id);
  TAssert.AssertTrue('only the id', R.Hit(0).Document.Find('title') = nil);
end;

procedure TContractTests.Get_RoundTrip;
var
  H: ISearchHit;
  D: TJsonValue;
begin
  H := FIndex.Get('1');
  TAssert.AssertTrue(H <> nil);
  TAssert.AssertEquals('1', H.Id);
  D := H.Document;
  TAssert.AssertEquals('Bebida quente servida no café da manhã', D.Find('body').AsString);
  TAssert.AssertEquals(7.5, D.Find('price').AsDouble, 0);
  TAssert.AssertEquals(Int64(10), D.Find('stock').AsInt64);
  TAssert.AssertTrue(D.Find('available').AsBoolean);
  TAssert.AssertEquals(SearchInstantToMs(Day(1)), D.Find('created_at').AsInt64);
  TAssert.AssertEquals(2, D.Find('tags').Count);
  TAssert.AssertEquals('café', D.Find('tags').Items[1].AsString);
  TAssert.AssertEquals('Bar "Zé"', FIndex.Get('4').Document.Find('category').AsString);
  TAssert.AssertEquals('C:\doces\', FIndex.Get('5').Document.Find('category').AsString);
  TAssert.AssertTrue('missing', FIndex.Get('nope') = nil);
end;

procedure TContractTests.GetMany_InOrderAsked;
begin
  TAssert.AssertEquals('3,1', Ids(FIndex.GetMany(['3', 'nope', '1'])));
  TAssert.AssertEquals('', Ids(FIndex.GetMany(['nope'])));
end;

procedure TContractTests.Upsert_ReplacesWholeDocument;
var
  D: TJsonValue;
begin
  FIndex.Upsert([TSearchDocument.New('7').Str('title', 'Quindim novo')]).WaitFor(ContractWait);
  D := FIndex.Get('7').Document;
  TAssert.AssertEquals('Quindim novo', D.Find('title').AsString);
  TAssert.AssertTrue('body gone', D.Find('body') = nil);
  TAssert.AssertTrue('price gone', D.Find('price') = nil);
  TAssert.AssertEquals('7', Find('novo'));
  TAssert.AssertEquals('', Find('amarelo'));
  TAssert.AssertEquals(Int64(7), FIndex.Search('').Execute.Total);
end;

procedure TContractTests.Delete_MissingId_NoError;
begin
  FIndex.Delete(['7', 'nope']).WaitFor(ContractWait);
  TAssert.AssertTrue(FIndex.Get('7') = nil);
  TAssert.AssertEquals('1,2,3,4,5,6', Find(''));
  FIndex.Delete(['nope']).WaitFor(ContractWait);
  TAssert.AssertEquals(Int64(6), FIndex.Search('').Execute.Total);
end;

procedure TContractTests.DeleteWhere_RemovesMatches;
begin
  FIndex.DeleteWhere(F.Eq('category', 'bebida')).WaitFor(ContractWait);
  TAssert.AssertEquals('2,4,5,6,7', Find(''));
  FIndex.DeleteWhere(F.Eq('category', 'nothing')).WaitFor(ContractWait);
  TAssert.AssertEquals('2,4,5,6,7', Find(''));
end;

procedure TContractTests.EnsureIndex_Again_KeepsDocuments;
begin
  FIndex := FEngine.EnsureIndex(NewSchema);
  TAssert.AssertTrue(FEngine.IndexExists(INDEX_NAME));
  TAssert.AssertEquals('1,3', Find('café'));
end;

procedure TContractTests.Index_NeverEnsured_NotFound;
var
  LIndex: ISearchIndex;
begin
  FEngine.DropIndex('contract_never');
  TAssert.AssertFalse(FEngine.IndexExists('contract_never'));
  LIndex := FEngine.Index('contract_never');
  TAssert.AssertEquals('contract_never', LIndex.Name);
  try
    LIndex.Search('x').Execute;
    TAssert.Fail('Searching an index never ensured must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos('contract_never', E.Message + E.EngineMessage) > 0);
  end;
end;

procedure TContractTests.DropIndex_Missing_NoError;
begin
  FEngine.DropIndex(INDEX_NAME);
  TAssert.AssertFalse(FEngine.IndexExists(INDEX_NAME));
  FEngine.DropIndex(INDEX_NAME);
  TAssert.AssertFalse(FEngine.IndexExists(INDEX_NAME));
end;


{ 0.2.0: ReplaceIndex, ListIds, Highlight, SetSynonyms (design, section 12) }

function TContractTests.HitById(const AResult: ISearchResult; const AId: string): ISearchHit;
var
  I: Integer;
begin
  for I := 0 to AResult.Count - 1 do
    if AResult.Hit(I).Id = AId then
      Exit(AResult.Hit(I));
  Result := nil;
  TAssert.Fail('No hit "' + AId + '"');
end;

// "text*|text" for the parts, * after a matched one; '(none)' without.
function PartsText(const AHit: ISearchHit; const AField: string): string;
var
  H: TSearchHighlight;
  I: Integer;
begin
  if not AHit.FindHighlight(AField, H) then
    Exit('(none)');
  Result := '';
  for I := 0 to High(H.Parts) do
  begin
    if I > 0 then
      Result := Result + '|';
    Result := Result + H.Parts[I].Text;
    if H.Parts[I].Matched then
      Result := Result + '*';
  end;
end;

function StagingSchema: ISearchSchema;
begin
  Result := TSearchSchema.New(STAGING_NAME)
    .Text('title')
    .Keyword('kind', [sfFilter]);
end;

procedure TContractTests.ReplaceIndex_ExistingTarget;
var
  LStaging: ISearchIndex;
begin
  FEngine.DropIndex(STAGING_NAME);
  LStaging := FEngine.EnsureIndex(StagingSchema);
  LStaging.Upsert([TSearchDocument.New('n1').Str('title', 'Novo bolo').Str('kind', 'x'),
    TSearchDocument.New('n2').Str('title', 'Outro bolo').Str('kind', 'y')]).WaitFor(ContractWait);
  LStaging.SetSynonyms([TSearchSynonym.Equivalent(['novo', 'fresquinho'])]);
  FEngine.ReplaceIndex(INDEX_NAME, STAGING_NAME);
  TAssert.AssertFalse('the source name is free', FEngine.IndexExists(STAGING_NAME));
  TAssert.AssertTrue(FEngine.IndexExists(INDEX_NAME));
  TAssert.AssertEquals('the new documents only', 'n1,n2', Find(''));
  TAssert.AssertTrue('an old document is gone', FIndex.Get('1') = nil);
  TAssert.AssertEquals('the new schema', 'n1', Where(F.Eq('kind', 'x')));
  TAssert.AssertEquals('the new synonyms', 'n1', Find('fresquinho'));
end;

procedure TContractTests.ReplaceIndex_MissingTarget_Renames;
var
  LStaging: ISearchIndex;
begin
  FEngine.DropIndex(STAGING_NAME);
  LStaging := FEngine.EnsureIndex(SearchSchemaRenamed(NewSchema, STAGING_NAME));
  LStaging.Upsert(SeedDocs).WaitFor(ContractWait);
  FEngine.DropIndex(INDEX_NAME);
  FEngine.ReplaceIndex(INDEX_NAME, STAGING_NAME);
  TAssert.AssertFalse(FEngine.IndexExists(STAGING_NAME));
  TAssert.AssertTrue(FEngine.IndexExists(INDEX_NAME));
  TAssert.AssertEquals('1,3', Find('café'));
  TAssert.AssertEquals('1,3', Where(F.Eq('category', 'bebida')));
end;

procedure TContractTests.ReplaceIndex_Twice_SameSourceName;
var
  LRound: Integer;
  LStaging: ISearchIndex;
begin
  for LRound := 1 to 2 do
  begin
    FEngine.DropIndex(STAGING_NAME);
    LStaging := FEngine.EnsureIndex(StagingSchema);
    LStaging.Upsert([TSearchDocument.New('r' + IntToStr(LRound)).Str('title', 'Rodada')])
      .WaitFor(ContractWait);
    FEngine.ReplaceIndex(INDEX_NAME, STAGING_NAME);
    TAssert.AssertEquals(Format('round %d', [LRound]), 'r' + IntToStr(LRound), Find(''));
  end;
  TAssert.AssertFalse(FEngine.IndexExists(STAGING_NAME));
end;

procedure TContractTests.ReplaceIndex_MissingSource_NotFound;
begin
  FEngine.DropIndex(STAGING_NAME);
  try
    FEngine.ReplaceIndex(INDEX_NAME, STAGING_NAME);
    TAssert.Fail('A missing source must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos(STAGING_NAME, E.Message) > 0);
  end;
  TAssert.AssertEquals('the target untouched', '1,3', Find('café'));
  try
    FEngine.ReplaceIndex(INDEX_NAME, INDEX_NAME);
    TAssert.Fail('Replacing an index with itself must raise');
  except
    on ESearchArgumentError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TContractTests.ListIds_AllAndFiltered;
begin
  TAssert.AssertEquals('1,2,3,4,5,6,7', SortedText(FIndex.ListIds));
  TAssert.AssertEquals('1,3', SortedText(FIndex.ListIds(F.Eq('category', 'bebida'))));
  TAssert.AssertEquals('', SortedText(FIndex.ListIds(F.Eq('category', 'nothing'))));
  try
    FIndex.ListIds(F.Eq('title', 'x'));
    TAssert.Fail('A filter on a field not declared filterable must raise');
  except
    on ESearchRequestError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TContractTests.ListIds_PastMaxHits;
var
  LIndex: ISearchIndex;
  LDocs: TSearchDocuments;
  I: Integer;
begin
  FEngine.DropIndex(STAGING_NAME);
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(STAGING_NAME).Text('title').WithMaxHits(2));
  LDocs := nil;
  SetLength(LDocs, 5);
  for I := 0 to High(LDocs) do
    LDocs[I] := TSearchDocument.New('m' + IntToStr(I)).Str('title', 'x');
  LIndex.Upsert(LDocs).WaitFor(ContractWait);
  TAssert.AssertEquals('m0,m1,m2,m3,m4', SortedText(LIndex.ListIds));
  FEngine.DropIndex(STAGING_NAME);
end;

procedure TContractTests.Highlight_MatchedWords;
var
  R: ISearchResult;
begin
  R := FIndex.Search('café').Highlight(['title', 'body']).Execute;
  TAssert.AssertEquals('Café*| com leite', PartsText(HitById(R, '1'), 'title'));
  TAssert.AssertEquals('Bebida quente servida no |café*| da manhã', PartsText(HitById(R, '1'), 'body'));
  TAssert.AssertEquals('Café*| preto', PartsText(HitById(R, '3'), 'title'));
  TAssert.AssertEquals('no match in the field', '(none)', PartsText(HitById(R, '3'), 'body'));
  TAssert.AssertEquals('a field not asked', '(none)',
    PartsText(HitById(FIndex.Search('café').Highlight(['body']).Execute, '3'), 'title'));
end;

procedure TContractTests.Highlight_PrefixAndAccents;
var
  R: ISearchResult;
  H: TSearchHighlight;
begin
  R := FIndex.Search('caf').Highlight(['title']).Execute;
  TAssert.AssertEquals('the matched start only', 'Caf*|é com leite', PartsText(HitById(R, '1'), 'title'));
  R := FIndex.Search('agua').Highlight(['title']).Execute;
  TAssert.AssertEquals('Água*| de coco', PartsText(HitById(R, '4'), 'title'));
  TAssert.AssertTrue(HitById(R, '4').FindHighlight('title', H));
  TAssert.AssertEquals('Água de coco', H.Text);
end;

procedure TContractTests.Highlight_HtmlEscaped;
var
  R: ISearchResult;
  H: TSearchHighlight;
begin
  FIndex.Upsert([TSearchDocument.New('8').Str('title', 'Pão <b>de</b> queijo & "aspas"')])
    .WaitFor(ContractWait);
  R := FIndex.Search('queijo').Highlight(['title']).Execute;
  TAssert.AssertTrue(HitById(R, '8').FindHighlight('title', H));
  TAssert.AssertEquals('Pão &lt;b&gt;de&lt;/b&gt; <mark>queijo</mark> &amp; &quot;aspas&quot;', H.ToHtml);
  TAssert.AssertEquals('Pão &lt;b&gt;de&lt;/b&gt; [queijo] &amp; &quot;aspas&quot;', H.ToHtml('[', ']'));
  TAssert.AssertEquals('Pão <b>de</b> queijo & "aspas"', H.Text);
end;

procedure TContractTests.Highlight_NoText_OrFieldNotReturned;
var
  R: ISearchResult;
begin
  R := FIndex.Search('').Highlight(['title']).Execute;
  TAssert.AssertEquals('an empty text marks nothing', '(none)', PartsText(HitById(R, '1'), 'title'));
  R := FIndex.Search('café').Fields(['id']).Highlight(['title']).Execute;
  TAssert.AssertTrue('only the id comes back', HitById(R, '1').Document.Find('title') = nil);
  TAssert.AssertTrue('the document has no highlight member', HitById(R, '1').Document.Find('_formatted') = nil);
  TAssert.AssertEquals('Café*| com leite', PartsText(HitById(R, '1'), 'title'));
end;

procedure TContractTests.Synonyms_EquivalentAndOneWay;
begin
  FIndex.SetSynonyms([
    TSearchSynonym.Equivalent(['moleque', 'piá']),
    TSearchSynonym.OneWay('amendoim', ['polvilho'])]);
  TAssert.AssertEquals('piá', '5', Find('piá'));
  TAssert.AssertEquals('PIA, accents and case folded', '5', Find('PIA'));
  TAssert.AssertEquals('moleque', '5', Find('moleque'));
  TAssert.AssertEquals('the root finds its words', '2,5', Find('amendoim'));
  TAssert.AssertEquals('a word doesn''t find the root', '2', Find('polvilho'));
end;

procedure TContractTests.Synonyms_SeveralWords;
begin
  FIndex.SetSynonyms([TSearchSynonym.Equivalent(['café preto', 'expresso'])]);
  TAssert.AssertEquals('expresso', '3', Find('expresso'));
  TAssert.AssertEquals('café preto', '3', Find('café preto'));
end;

procedure TContractTests.Synonyms_ReplacedAndCleared;
begin
  FIndex.SetSynonyms([TSearchSynonym.Equivalent(['moleque', 'piá'])]);
  TAssert.AssertEquals('5', Find('piá'));
  FIndex.SetSynonyms([TSearchSynonym.Equivalent(['quindim', 'piá'])]);
  TAssert.AssertEquals('the groups replaced', '7', Find('piá'));
  FIndex.SetSynonyms([]);
  TAssert.AssertEquals('cleared', '', Find('piá'));
end;

initialization
  TDUnitX.RegisterTestFixture(TContractTests);

end.
