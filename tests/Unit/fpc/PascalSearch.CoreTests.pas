unit PascalSearch.CoreTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalSearch.CoreTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the pieces that need no engine: the id, index and field name
  checks, values (instants as Unix milliseconds, numbers in plain decimal),
  the schema builder, documents and their JSON, the filter builder's
  refusals and structure, the query builder's checks and defaults, the words
  text (tmWords) and the facet order.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Math,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Query;

type
  TProductDto = class
  private
    FTitle: string;
    FPrice: Double;
    FId: Integer;
  published
    property Id: Integer read FId write FId;
    property Title: string read FTitle write FTitle;
    property Price: Double read FPrice write FPrice;
  end;

  TCoreTests = class(TTestCase)
  published
    procedure Id_CommonGround_Accepted;
    procedure Id_OutsideCommonGround_Refused;
    procedure IndexName_Checked;
    procedure FieldName_Checked;
    procedure Instant_UnixMilliseconds;
    procedure NumberText_PlainDecimal;
    procedure NumberText_NaN_Refused;
    procedure Value_FilterText;
    procedure Schema_Fields;
    procedure Schema_Refusals;
    procedure Document_ToJson;
    procedure Document_SetAgain_ReplacesInPlace;
    procedure Document_Refusals;
    procedure Document_FromJson;
    procedure Document_FromObject;
    procedure Filter_Structure;
    procedure Filter_IntegerLiteral_IsInteger;
    procedure Filter_Refusals;
    procedure Query_Defaults;
    procedure Query_Builder;
    procedure Query_Refusals;
    procedure WordsText_RemovesOperators;
    procedure FacetValues_Order;
  end;

implementation

type
  TNilExecutor = class(TInterfacedObject, ISearchExecutor)
  public
    function ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
  end;

function TNilExecutor.ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
begin
  Result := nil;
end;

function NewQuery(const AText: string): ISearchQuery;
begin
  Result := TSearchQuery.Create(TNilExecutor.Create, AText);
end;

procedure ExpectArgumentError(const AWhat: string; AOk: Boolean);
begin
  TAssert.AssertFalse(AWhat + ' must raise ESearchArgumentError', AOk);
end;

{ TCoreTests }

procedure TCoreTests.Id_CommonGround_Accepted;
begin
  TAssert.AssertTrue(SearchIsValidId('a-b_C9'));
  TAssert.AssertTrue(SearchIsValidId('123'));
  TAssert.AssertTrue(SearchIsValidId(StringOfChar('x', 511)));
end;

procedure TCoreTests.Id_OutsideCommonGround_Refused;
begin
  TAssert.AssertFalse('empty', SearchIsValidId(''));
  TAssert.AssertFalse('space', SearchIsValidId('a b'));
  TAssert.AssertFalse('slash', SearchIsValidId('a/b'));
  TAssert.AssertFalse('dot', SearchIsValidId('a.b'));
  TAssert.AssertFalse('accent', SearchIsValidId('á'));
  TAssert.AssertFalse('512', SearchIsValidId(StringOfChar('x', 512)));
  try
    SearchCheckId('a b');
    TAssert.Fail('SearchCheckId must raise');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('a b', E.Message) > 0);
  end;
end;

procedure TCoreTests.IndexName_Checked;
begin
  TAssert.AssertTrue(SearchIsValidIndexName('products_v2-a'));
  TAssert.AssertFalse(SearchIsValidIndexName('a b'));
  TAssert.AssertFalse(SearchIsValidIndexName(''));
  TAssert.AssertFalse(SearchIsValidIndexName(StringOfChar('x', 65)));
end;

procedure TCoreTests.FieldName_Checked;
var
  LOk: Boolean;
begin
  TAssert.AssertTrue(SearchIsValidFieldName('created_at'));
  TAssert.AssertTrue(SearchIsValidFieldName('_x1'));
  TAssert.AssertFalse('digit first', SearchIsValidFieldName('1x'));
  TAssert.AssertFalse('dot', SearchIsValidFieldName('a.b'));
  TAssert.AssertFalse('dash', SearchIsValidFieldName('a-b'));
  TAssert.AssertFalse('space', SearchIsValidFieldName('a b'));
  LOk := True;
  try
    SearchCheckFieldName('id');
  except
    on E: ESearchArgumentError do
      LOk := False;
  end;
  ExpectArgumentError('A field named id', LOk);
end;

procedure TCoreTests.Instant_UnixMilliseconds;
var
  LUtc: TDateTime;
begin
  TAssert.AssertEquals(Int64(0), SearchInstantToMs(EncodeDate(1970, 1, 1)));
  TAssert.AssertEquals(Int64(1767225600000), SearchInstantToMs(EncodeDate(2026, 1, 1)));
  LUtc := EncodeDate(2026, 1, 1) + EncodeTime(0, 0, 0, 123);
  TAssert.AssertEquals(Int64(1767225600123), SearchInstantToMs(LUtc));
  TAssert.AssertEquals(Int64(1767225600123), SearchInstantToMs(SearchMsToInstant(1767225600123)));
  TAssert.AssertEquals(Int64(-86400000), SearchInstantToMs(EncodeDate(1969, 12, 31)));
end;

procedure TCoreTests.NumberText_PlainDecimal;
begin
  TAssert.AssertEquals('7.5', SearchNumberText(7.5));
  TAssert.AssertEquals('0', SearchNumberText(0));
  TAssert.AssertEquals('100', SearchNumberText(100));
  TAssert.AssertEquals('-3.25', SearchNumberText(-3.25));
  TAssert.AssertEquals('1000000000000000000000', SearchNumberText(1e21));
  TAssert.AssertEquals('-25000000000000000000000', SearchNumberText(-2.5e22));
  TAssert.AssertEquals('0.00000015', SearchNumberText(1.5e-7));
  TAssert.AssertEquals('0.1', SearchNumberText(0.1));
end;

procedure TCoreTests.NumberText_NaN_Refused;
var
  LOk: Boolean;
begin
  // Math's constants: computing 0/0 raises EInvalidOp on FPC before the
  // library sees the value.
  LOk := True;
  try
    SearchNumberText(NaN);
  except
    on E: ESearchArgumentError do
      LOk := False;
  end;
  ExpectArgumentError('NaN', LOk);
  LOk := True;
  try
    TSearchValue.OfNumber(Infinity);
  except
    on E: ESearchArgumentError do
      LOk := False;
  end;
  ExpectArgumentError('Infinity', LOk);
end;

procedure TCoreTests.Value_FilterText;
begin
  TAssert.AssertEquals('Bar "Zé"', TSearchValue.OfString('Bar "Zé"').ToFilterText);
  TAssert.AssertEquals('true', TSearchValue.OfBoolean(True).ToFilterText);
  TAssert.AssertEquals('false', TSearchValue.OfBoolean(False).ToFilterText);
  TAssert.AssertEquals('-42', TSearchValue.OfInteger(-42).ToFilterText);
  TAssert.AssertEquals('1767225600000', TSearchValue.OfInstant(EncodeDate(2026, 1, 1)).ToFilterText);
  TAssert.AssertTrue(TSearchValue.OfInstant(EncodeDate(2026, 1, 1)).IsNumeric);
  TAssert.AssertFalse(TSearchValue.OfBoolean(True).IsNumeric);
end;

procedure TCoreTests.Schema_Fields;
var
  S: ISearchSchema;
  LField: TSearchField;
begin
  S := TSearchSchema.New('products')
    .Text('title')
    .Keyword('category', [sfFilter, sfFacet])
    .Keywords('tags', [sfFacet])
    .Num('price', [sfFilter, sfSort])
    .Int('stock', [sfSort])
    .Bool('available', [sfFilter])
    .Instant('created_at', [sfFilter, sfSort])
    .Stored('note');
  TAssert.AssertEquals('products', S.Name);
  TAssert.AssertEquals(8, S.FieldCount);
  TAssert.AssertEquals(SEARCH_DEFAULT_MAX_HITS, S.MaxHits);
  TAssert.AssertTrue(S.FindField('tags', LField));
  TAssert.AssertTrue('a facet is filterable', LField.IsFilterable);
  TAssert.AssertFalse(LField.IsSortable);
  TAssert.AssertTrue(S.FindField('title', LField));
  TAssert.AssertTrue(LField.IsSearchable);
  TAssert.AssertFalse(LField.IsFilterable);
  TAssert.AssertTrue(S.FindField('stock', LField));
  TAssert.AssertTrue(LField.Kind = skInteger);
  TAssert.AssertFalse(S.FindField('nope', LField));
  TAssert.AssertEquals(5000, S.WithMaxHits(5000).MaxHits);
end;

procedure TCoreTests.Schema_Refusals;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    TSearchSchema.New('a b');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('An index name with a space', LOk);
  LOk := True;
  try
    TSearchSchema.New('p').Text('title').Keyword('title');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field declared twice', LOk);
  LOk := True;
  try
    TSearchSchema.New('p').Keyword('id');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field named id', LOk);
  LOk := True;
  try
    TSearchSchema.New('p').Keywords('tags', [sfSort]);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Sorting an array field', LOk);
  LOk := True;
  try
    TSearchSchema.New('p').WithMaxHits(0);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('MaxHits 0', LOk);
end;

procedure TCoreTests.Document_ToJson;
var
  D: ISearchDocument;
begin
  D := TSearchDocument.New('42')
    .Str('title', 'Café "com" leite\')
    .Strs('tags', ['quente', 'café'])
    .Num('price', 7.5)
    .Int('stock', 3)
    .Bool('available', True)
    .Instant('created_at', EncodeDate(2026, 1, 1))
    .Null('category')
    .Json('extra', '{"a":[1,2]}');
  TAssert.AssertEquals('42', D.Id);
  TAssert.AssertEquals('{"id":"42","title":"Café \"com\" leite\\","tags":["quente","café"],' +
    '"price":7.5,"stock":3,"available":true,"created_at":1767225600000,"category":null,' +
    '"extra":{"a":[1,2]}}', D.ToJson);
  TAssert.AssertEquals(8, D.FieldCount);
  TAssert.AssertEquals('price', D.FieldName(2));
  TAssert.AssertTrue(D.Find('nope') = nil);
  TAssert.AssertEquals(Int64(3), D.Find('stock').AsInt64);
end;

procedure TCoreTests.Document_SetAgain_ReplacesInPlace;
var
  D: ISearchDocument;
begin
  D := TSearchDocument.New('1').Str('a', 'x').Int('b', 1).Str('a', 'y');
  TAssert.AssertEquals('{"id":"1","a":"y","b":1}', D.ToJson);
end;

procedure TCoreTests.Document_Refusals;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    TSearchDocument.New('a/b');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('An id with a slash', LOk);
  LOk := True;
  try
    TSearchDocument.New('1').Str('id', '2');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field named id', LOk);
  LOk := True;
  try
    TSearchDocument.New('1').Str('a b', 'x');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field name with a space', LOk);
  LOk := True;
  try
    TSearchDocument.New('1').Json('a', '{bad');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Invalid JSON in Json()', LOk);
end;

procedure TCoreTests.Document_FromJson;
var
  D: ISearchDocument;
  LOk: Boolean;
begin
  D := TSearchDocument.FromJson('{"title":"Água","id":42,"nested":{"x":true}}');
  TAssert.AssertEquals('42', D.Id);
  TAssert.AssertEquals('{"id":"42","title":"Água","nested":{"x":true}}', D.ToJson);
  D := TSearchDocument.FromJson('{"id":"abc"}');
  TAssert.AssertEquals('{"id":"abc"}', D.ToJson);
  LOk := True;
  try
    TSearchDocument.FromJson('{"title":"x"}');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('No id', LOk);
  LOk := True;
  try
    TSearchDocument.FromJson('[1]');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Not an object', LOk);
  LOk := True;
  try
    TSearchDocument.FromJson('{"id":1.5}');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A fractional id', LOk);
  LOk := True;
  try
    TSearchDocument.FromJson('{"id":"a b"}');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('An invalid id', LOk);
end;

procedure TCoreTests.Document_FromObject;
var
  LDto: TProductDto;
  D: ISearchDocument;
begin
  LDto := TProductDto.Create;
  try
    LDto.Id := 99;
    LDto.Title := 'Pão';
    LDto.Price := 6.5;
    D := TSearchDocument.FromObject('7', LDto);
  finally
    LDto.Free;
  end;
  TAssert.AssertEquals('7', D.Id);
  TAssert.AssertEquals('{"id":"7","title":"Pão","price":6.5}', D.ToJson);
end;

procedure TCoreTests.Filter_Structure;
var
  LFilter: ISearchFilter;
begin
  LFilter := F.All([
    F.Eq('category', 'bebida'),
    F.Between('price', 5.0, 8.0),
    F.Any([F.Eq('available', True), F.Gt('stock', Int64(0))]),
    F.NoneOf('tags', ['gelada', 'doce']),
    F.Ge('created_at', F.At(EncodeDate(2026, 1, 1)))]);
  TAssert.AssertTrue(LFilter.Op = fopAll);
  TAssert.AssertEquals(5, LFilter.ChildCount);
  TAssert.AssertEquals('category', LFilter.Child(0).Field);
  TAssert.AssertEquals('bebida', LFilter.Child(0).Value(0).AsString);
  TAssert.AssertTrue(LFilter.Child(1).Op = fopBetween);
  TAssert.AssertEquals(2, LFilter.Child(1).ValueCount);
  TAssert.AssertEquals(8.0, LFilter.Child(1).Value(1).AsNumber, 0);
  TAssert.AssertTrue(LFilter.Child(2).Op = fopAny);
  TAssert.AssertTrue(LFilter.Child(2).Child(0).Value(0).Kind = svBoolean);
  TAssert.AssertEquals(2, LFilter.Child(3).ValueCount);
  TAssert.AssertTrue(LFilter.Child(4).Value(0).Kind = svInstant);
  TAssert.AssertEquals(Int64(1767225600000), LFilter.Child(4).Value(0).AsInteger);
  LFilter := F.AnyOf('id', ['1', '7']);
  TAssert.AssertEquals('id', LFilter.Field);
end;

procedure TCoreTests.Filter_IntegerLiteral_IsInteger;
begin
  // Overload resolution: an integer literal picks Int64, not Double, on both
  // compilers; a real literal picks Double.
  TAssert.AssertTrue(F.Eq('stock', 3).Value(0).Kind = svInteger);
  TAssert.AssertTrue(F.Gt('stock', 3).Value(0).Kind = svInteger);
  TAssert.AssertTrue(F.Eq('price', 7.5).Value(0).Kind = svNumber);
  TAssert.AssertTrue(F.Between('stock', 1, 2).Value(0).Kind = svInteger);
  TAssert.AssertTrue(F.AnyOf('stock', [1, 2]).Value(1).Kind = svInteger);
end;

procedure TCoreTests.Filter_Refusals;
var
  LOk: Boolean;
  LNone: array of string;
begin
  LOk := True;
  try
    F.Eq('1x', 'a');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field starting with a digit', LOk);
  LOk := True;
  try
    F.Eq('a) OR (b', 'a');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A field name with syntax in it', LOk);
  LOk := True;
  try
    F.Gt('title', TSearchValue.OfString('a'));
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Comparing a string', LOk);
  LOk := True;
  try
    F.Gt('available', TSearchValue.OfBoolean(True));
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Comparing a boolean', LOk);
  LOk := True;
  try
    F.Eq('id', 3);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('An integer id', LOk);
  LOk := True;
  try
    F.Gt('id', TSearchValue.OfString('3'));
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Comparing the id', LOk);
  SetLength(LNone, 0);
  LOk := True;
  try
    F.AnyOf('category', LNone);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('AnyOf of nothing', LOk);
  LOk := True;
  try
    F.All([]);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('All of nothing', LOk);
  LOk := True;
  try
    F.Any([F.Eq('a', 'b'), nil]);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A nil child', LOk);
end;

procedure TCoreTests.Query_Defaults;
var
  R: TSearchRequest;
begin
  R := NewQuery('café').Request;
  TAssert.AssertEquals('café', R.Text);
  TAssert.AssertEquals(1, R.Page);
  TAssert.AssertEquals(SEARCH_DEFAULT_PAGE_SIZE, R.PageSize);
  TAssert.AssertTrue(R.Words = swAll);
  TAssert.AssertTrue(R.TextMode = tmWords);
  TAssert.AssertTrue(R.Filter = nil);
  TAssert.AssertEquals(0, Integer(Length(R.Sorts)));
end;

procedure TCoreTests.Query_Builder;
var
  R: TSearchRequest;
begin
  R := NewQuery('-café "preto"')
    .Where(F.Eq('category', 'bebida'))
    .OrderBy('title')
    .OrderBy('price', soDesc)
    .ThenBy('created_at')
    .Page(3, 0)
    .Facets(['category', 'tags'])
    .Fields(['id', 'title'])
    .Words(swRelaxed)
    .Raw('showRankingScore', 'true')
    .Request;
  TAssert.AssertEquals(2, Integer(Length(R.Sorts)));
  TAssert.AssertEquals('price', R.Sorts[0].Field);
  TAssert.AssertTrue(R.Sorts[0].Order = soDesc);
  TAssert.AssertEquals('created_at', R.Sorts[1].Field);
  TAssert.AssertTrue(R.Sorts[1].Order = soAsc);
  TAssert.AssertEquals(3, R.Page);
  TAssert.AssertEquals(0, R.PageSize);
  TAssert.AssertEquals('tags', R.Facets[1]);
  TAssert.AssertEquals('title', R.Fields[1]);
  TAssert.AssertTrue(R.Words = swRelaxed);
  TAssert.AssertEquals('showRankingScore', R.Raw[0].Name);
  TAssert.AssertEquals('café preto', R.TextToSend);
  R.TextMode := tmEngine;
  TAssert.AssertEquals('-café "preto"', R.TextToSend);
end;

procedure TCoreTests.Query_Refusals;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    NewQuery('x').Page(0, 10);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Page 0', LOk);
  LOk := True;
  try
    NewQuery('x').Page(1, SEARCH_MAX_PAGE_SIZE + 1);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A page of 251', LOk);
  LOk := True;
  try
    NewQuery('x').OrderBy('id');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('Sorting by id', LOk);
  LOk := True;
  try
    NewQuery('x').Facets(['a b']);
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A facet with a space', LOk);
  LOk := True;
  try
    NewQuery('x').Raw('x', '{bad');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A Raw value that is not JSON', LOk);
  LOk := True;
  try
    NewQuery('x').Raw('a&b', '1');
  except
    on E: ESearchArgumentError do LOk := False;
  end;
  ExpectArgumentError('A Raw name with "&"', LOk);
end;

procedure TCoreTests.WordsText_RemovesOperators;
begin
  TAssert.AssertEquals('café preto', SearchWordsText('-café "preto"'));
  TAssert.AssertEquals('Café-com-leite', SearchWordsText('Café-com-leite'));
  TAssert.AssertEquals('a', SearchWordsText('--a'));
  TAssert.AssertEquals('', SearchWordsText('"'));
  TAssert.AssertEquals('café', SearchWordsText('  "café  '));
  TAssert.AssertEquals('50% d''água', SearchWordsText('50% d''água'));
end;

procedure TCoreTests.FacetValues_Order;
var
  V: TArray<TSearchFacetValue>;

  procedure Put(AIndex: Integer; const AValue: string; ACount: Integer);
  begin
    V[AIndex].Value := AValue;
    V[AIndex].Count := ACount;
  end;

begin
  SetLength(V, 4);
  Put(0, 'salgado', 1);
  Put(1, 'bebida', 2);
  Put(2, 'Bar', 1);
  Put(3, 'agua', 2);
  SearchSortFacetValues(V);
  TAssert.AssertEquals('agua', V[0].Value);
  TAssert.AssertEquals('bebida', V[1].Value);
  TAssert.AssertEquals('Bar', V[2].Value);
  TAssert.AssertEquals('salgado', V[3].Value);
end;

initialization
  RegisterTest(TCoreTests);

end.
