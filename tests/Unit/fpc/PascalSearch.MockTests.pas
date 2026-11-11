unit PascalSearch.MockTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalSearch.MockTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for what only the mock has: its test controls (DeferWrites,
  FailNextWrite, Unavailable), the refusals of engine-specific features (Raw,
  tmEngine), a document with a field of the wrong kind, a schema change that
  can't happen in place, and the choices the contract leaves to each engine
  (accent-sensitive equality, relaxed ranking). The contract itself is
  PascalSearch.ContractTests.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Mock;

type
  TMockTests = class(TTestCase)
  private
    FEngine: IMockSearchEngine;
    FIndex: ISearchIndex;
    function Ids(const AHits: ISearchHits): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DeferWrites_VisibleOnlyAfterWaitFor;
    procedure DeferWrites_WaitForAppliesEarlierWritesFirst;
    procedure FailNextWrite_SomeIds;
    procedure FailNextWrite_WholeBatch;
    procedure FailNextWrite_OnlyOnce;
    procedure WrongKind_RefusesThatDocumentOnly;
    procedure Unavailable_EveryCallRaises;
    procedure Raw_NotSupported;
    procedure EngineText_NotSupported;
    procedure SchemaKindChange_SchemaError;
    procedure Write_IndexNeverEnsured_NotFound;
    procedure Write_IndexDroppedBeforeApplied_WholeBatch;
    procedure Eq_AccentSensitive;
    procedure Relaxed_MoreWordsFirst;
    procedure Filter_ValueOfWrongKind_RequestError;
    procedure Facet_FilterableNotFacet_RequestError;
    procedure DocumentCount_AndIndexes;
    procedure Highlight_NotATextField_RequestError;
    procedure Highlight_SynonymWordsMarked;
    procedure ReplaceIndex_AppliesDeferredWritesFirst;
    procedure Synonyms_LongestKeyFirst;
    procedure Synonyms_Relaxed_CountsAGroupOnce;
  end;

implementation

function Schema: ISearchSchema;
begin
  Result := TSearchSchema.New('mock_products')
    .Text('title').Text('body')
    .Keyword('category', [sfFilter])
    .Keywords('tags', [sfFilter])
    .Num('price', [sfFilter, sfSort]);
end;

function Doc(const AId, ATitle, ABody: string): ISearchDocument;
begin
  Result := TSearchDocument.New(AId).Str('title', ATitle).Str('body', ABody);
end;

{ TMockTests }

procedure TMockTests.Setup;
begin
  FEngine := TMockSearchEngine.New;
  FIndex := FEngine.EnsureIndex(Schema);
end;

procedure TMockTests.TearDown;
begin
  FIndex := nil;
  FEngine := nil;
end;

function TMockTests.Ids(const AHits: ISearchHits): string;
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

procedure TMockTests.DeferWrites_VisibleOnlyAfterWaitFor;
var
  W: ISearchWrite;
begin
  FEngine.DeferWrites := True;
  W := FIndex.Upsert([Doc('1', 'Café', 'x')]);
  TAssert.AssertTrue('pending', W.Pending);
  TAssert.AssertEquals(1, FEngine.PendingWrites);
  TAssert.AssertEquals('not searchable yet', '', Ids(FIndex.Search('café').Execute));
  TAssert.AssertTrue('nor gettable', FIndex.Get('1') = nil);
  W.WaitFor;
  TAssert.AssertFalse(W.Pending);
  TAssert.AssertEquals(0, FEngine.PendingWrites);
  TAssert.AssertEquals('1', Ids(FIndex.Search('café').Execute));
  W.WaitFor;   // again: nothing to do
end;

procedure TMockTests.DeferWrites_WaitForAppliesEarlierWritesFirst;
var
  W1, W2, W3: ISearchWrite;
begin
  FEngine.DeferWrites := True;
  W1 := FIndex.Upsert([Doc('1', 'um', 'x'), Doc('2', 'dois', 'x')]);
  W2 := FIndex.Delete(['1']);
  W3 := FIndex.Upsert([Doc('3', 'tres', 'x')]);
  W2.WaitFor;
  TAssert.AssertFalse(W1.Pending);
  TAssert.AssertTrue('a later write still waits', W3.Pending);
  TAssert.AssertEquals('2', Ids(FIndex.Search('').Execute));
  W3.WaitFor;
  TAssert.AssertEquals('2,3', Ids(FIndex.Search('').Execute));
end;

procedure TMockTests.FailNextWrite_SomeIds;
begin
  FEngine.FailNextWrite(['2'], 'disk full');
  try
    FIndex.Upsert([Doc('1', 'a', 'x'), Doc('2', 'b', 'x')]).WaitFor;
    TAssert.Fail('WaitFor must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertFalse(E.WholeBatch);
      TAssert.AssertEquals(1, Integer(Length(E.Failures)));
      TAssert.AssertEquals('2', E.Failures[0].Id);
      TAssert.AssertEquals('disk full', E.Failures[0].Message);
    end;
  end;
  TAssert.AssertEquals('the other one was applied', '1', Ids(FIndex.Search('').Execute));
end;

procedure TMockTests.FailNextWrite_WholeBatch;
begin
  FEngine.FailNextWrite([], 'task failed', True);
  try
    FIndex.Upsert([Doc('1', 'a', 'x'), Doc('2', 'b', 'x')]).WaitFor;
    TAssert.Fail('WaitFor must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertTrue(E.WholeBatch);
      TAssert.AssertEquals(2, Integer(Length(E.Failures)));
      TAssert.AssertEquals('1', E.Failures[0].Id);
      TAssert.AssertEquals('2', E.Failures[1].Id);
    end;
  end;
  TAssert.AssertEquals('nothing applied', '', Ids(FIndex.Search('').Execute));
end;

procedure TMockTests.FailNextWrite_OnlyOnce;
begin
  FEngine.FailNextWrite(['1'], 'x');
  try
    FIndex.Upsert([Doc('1', 'a', 'x')]).WaitFor;
  except
    on E: ESearchWriteFailed do ;
  end;
  FIndex.Upsert([Doc('1', 'a', 'x')]).WaitFor;
  TAssert.AssertEquals('1', Ids(FIndex.Search('').Execute));
end;

procedure TMockTests.WrongKind_RefusesThatDocumentOnly;
begin
  try
    FIndex.Upsert([Doc('1', 'a', 'x').Str('price', 'abc'), Doc('2', 'b', 'x').Num('price', 2)])
      .WaitFor;
    TAssert.Fail('WaitFor must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertFalse(E.WholeBatch);
      TAssert.AssertEquals(1, Integer(Length(E.Failures)));
      TAssert.AssertEquals('1', E.Failures[0].Id);
      TAssert.AssertEquals('invalid_field_value', E.Failures[0].Code);
    end;
  end;
  TAssert.AssertEquals('2', Ids(FIndex.Search('').Execute));
end;

procedure TMockTests.Unavailable_EveryCallRaises;
var
  LCount: Integer;
begin
  FEngine.Unavailable := True;
  LCount := 0;
  try
    FIndex.Search('x').Execute;
  except
    on E: ESearchUnavailable do Inc(LCount);
  end;
  try
    FIndex.Upsert([Doc('1', 'a', 'x')]);
  except
    on E: ESearchUnavailable do Inc(LCount);
  end;
  try
    FEngine.IndexExists('mock_products');
  except
    on E: ESearchUnavailable do Inc(LCount);
  end;
  try
    FIndex.Get('1');
  except
    on E: ESearchUnavailable do Inc(LCount);
  end;
  TAssert.AssertEquals(4, LCount);
  FEngine.Unavailable := False;
  TAssert.AssertEquals(Int64(0), FIndex.Search('x').Execute.Total);
end;

procedure TMockTests.Raw_NotSupported;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    FIndex.Search('x').Raw('showRankingScore', 'true').Execute;
  except
    on E: ESearchNotSupported do LOk := False;
  end;
  TAssert.AssertFalse('Raw must raise ESearchNotSupported', LOk);
end;

procedure TMockTests.EngineText_NotSupported;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    FIndex.Search('-x').TextMode(tmEngine).Execute;
  except
    on E: ESearchNotSupported do LOk := False;
  end;
  TAssert.AssertFalse('tmEngine must raise ESearchNotSupported', LOk);
end;

procedure TMockTests.SchemaKindChange_SchemaError;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    FEngine.EnsureIndex(TSearchSchema.New('mock_products').Keyword('price'));
  except
    on E: ESearchSchemaError do
    begin
      LOk := False;
      TAssert.AssertTrue(E.Message, Pos('price', E.Message) > 0);
    end;
  end;
  TAssert.AssertFalse('A field changing kind must raise ESearchSchemaError', LOk);
  // A new field and other flags are fine.
  FEngine.EnsureIndex(Schema.Bool('available', [sfFilter]));
end;

procedure TMockTests.Write_IndexNeverEnsured_NotFound;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    FEngine.Index('never').Upsert([Doc('1', 'a', 'x')]);
  except
    on E: ESearchIndexNotFound do LOk := False;
  end;
  TAssert.AssertFalse('Writing to an index never ensured must raise', LOk);
end;

procedure TMockTests.Write_IndexDroppedBeforeApplied_WholeBatch;
var
  W: ISearchWrite;
begin
  FEngine.DeferWrites := True;
  W := FIndex.Upsert([Doc('1', 'a', 'x')]);
  FEngine.DropIndex('mock_products');
  try
    W.WaitFor;
    TAssert.Fail('WaitFor must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertTrue(E.WholeBatch);
      TAssert.AssertEquals('index_not_found', E.Failures[0].Code);
    end;
  end;
end;

procedure TMockTests.Eq_AccentSensitive;
begin
  FIndex.Upsert([Doc('1', 'a', 'x').Strs('tags', ['café'])]).WaitFor;
  TAssert.AssertEquals('1', Ids(FIndex.Search('').Where(F.Eq('tags', 'CAFÉ')).Execute));
  TAssert.AssertEquals('', Ids(FIndex.Search('').Where(F.Eq('tags', 'cafe')).Execute));
end;

procedure TMockTests.Relaxed_MoreWordsFirst;
begin
  FIndex.Upsert([Doc('1', 'bebida gelada', 'x'), Doc('2', 'bebida quente', 'x'),
    Doc('3', 'outra', 'x')]).WaitFor;
  TAssert.AssertEquals('2', Ids(FIndex.Search('bebida quente').Execute));
  TAssert.AssertEquals('2,1', Ids(FIndex.Search('bebida quente').Words(swRelaxed).Execute));
end;

procedure TMockTests.Filter_ValueOfWrongKind_RequestError;
var
  LOk: Boolean;
begin
  LOk := True;
  try
    FIndex.Search('').Where(F.Eq('price', 'abc')).Execute;
  except
    on E: ESearchRequestError do LOk := False;
  end;
  TAssert.AssertFalse('A string for a number field must raise', LOk);
  LOk := True;
  try
    FIndex.Search('').Where(F.Eq('category', 3)).Execute;
  except
    on E: ESearchRequestError do LOk := False;
  end;
  TAssert.AssertFalse('A number for a keyword field must raise', LOk);
end;

procedure TMockTests.Facet_FilterableNotFacet_RequestError;
begin
  // Stricter than Meilisearch, which facets any filterable field.
  try
    FIndex.Search('').Facets(['price']).Execute;
    TAssert.Fail('A facet on a field declared filter only must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('price', E.Message) > 0);
  end;
end;

procedure TMockTests.DocumentCount_AndIndexes;
begin
  TAssert.AssertEquals(0, FEngine.DocumentCount('mock_products'));
  TAssert.AssertEquals(-1, FEngine.DocumentCount('nope'));
  FIndex.Upsert([Doc('1', 'a', 'x'), Doc('2', 'b', 'x'), Doc('1', 'c', 'x')]).WaitFor;
  TAssert.AssertEquals('the same id twice is one document', 2, FEngine.DocumentCount('mock_products'));
  TAssert.AssertEquals('c', FIndex.Get('1').Document.Find('title').AsString);
end;

procedure TMockTests.Highlight_NotATextField_RequestError;
begin
  // Meilisearch would highlight any field; the mock (and Typesense) refuse.
  try
    FIndex.Search('x').Highlight(['category']).Execute;
    TAssert.Fail('A highlight on a field that isn''t Text must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('"category"', E.Message) > 0);
  end;
  try
    FIndex.Search('x').Highlight(['nope']).Execute;
    TAssert.Fail('A highlight on an undeclared field must raise');
  except
    on ESearchRequestError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TMockTests.Highlight_SynonymWordsMarked;
var
  R: ISearchResult;
  H: TSearchHighlight;
begin
  FIndex.Upsert([Doc('1', 'Televisão grande', 'tv de sala')]).WaitFor;
  FIndex.SetSynonyms([TSearchSynonym.Equivalent(['tv', 'televisão'])]);
  R := FIndex.Search('tv').Highlight(['title', 'body']).Execute;
  TAssert.AssertEquals(1, R.Count);
  TAssert.AssertTrue(R.Hit(0).FindHighlight('title', H));
  TAssert.AssertEquals('Televisão', H.Parts[0].Text);
  TAssert.AssertTrue(H.Parts[0].Matched);
  TAssert.AssertTrue(R.Hit(0).FindHighlight('body', H));
  TAssert.AssertEquals('<mark>tv</mark> de sala', H.ToHtml);
end;

procedure TMockTests.ReplaceIndex_AppliesDeferredWritesFirst;
var
  LStaging: ISearchIndex;
begin
  LStaging := FEngine.EnsureIndex(TSearchSchema.New('mock_new').Text('title'));
  FEngine.DeferWrites := True;
  LStaging.Upsert([Doc('n1', 'novo', '')]);
  TAssert.AssertEquals(1, FEngine.PendingWrites);
  FEngine.ReplaceIndex('mock_products', 'mock_new');
  TAssert.AssertEquals(0, FEngine.PendingWrites);
  TAssert.AssertEquals(1, FEngine.DocumentCount('mock_products'));
  TAssert.AssertEquals(-1, FEngine.DocumentCount('mock_new'));
  try
    FIndex.Search('').Where(F.Eq('category', 'x')).Execute;
    TAssert.Fail('The new schema has no "category"');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue('the schema carries the target''s name: ' + E.Message,
        Pos('"mock_products"', E.Message) > 0);
  end;
end;

procedure TMockTests.Synonyms_LongestKeyFirst;
begin
  FIndex.Upsert([Doc('1', 'cafezinho', ''), Doc('2', 'chá', ''), Doc('3', 'café', 'preto')]).WaitFor;
  FIndex.SetSynonyms([
    TSearchSynonym.OneWay('café preto', ['cafezinho']),
    TSearchSynonym.OneWay('café', ['chá'])]);
  TAssert.AssertEquals('"café preto" is one key', '1,3', Ids(FIndex.Search('café preto').Execute));
  TAssert.AssertEquals('cafezinho by the prefix, chá by the synonym', '1,2,3',
    Ids(FIndex.Search('café').Execute));
end;

procedure TMockTests.Synonyms_Relaxed_CountsAGroupOnce;
begin
  FIndex.Upsert([Doc('1', 'cafezinho', ''), Doc('2', 'café preto forte', '')]).WaitFor;
  FIndex.SetSynonyms([TSearchSynonym.Equivalent(['café preto', 'cafezinho'])]);
  TAssert.AssertEquals('both match the group, then "forte"', '2,1',
    Ids(FIndex.Search('café preto forte').Words(swRelaxed).Execute));
end;

initialization
  RegisterTest(TMockTests);

end.
