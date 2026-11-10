unit PascalSearch.MockTests;

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
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Mock;

type
  [TestFixture]
  TMockTests = class
  private
    FEngine: IMockSearchEngine;
    FIndex: ISearchIndex;
    function Ids(const AHits: ISearchHits): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure DeferWrites_VisibleOnlyAfterWaitFor;
    [Test] procedure DeferWrites_WaitForAppliesEarlierWritesFirst;
    [Test] procedure FailNextWrite_SomeIds;
    [Test] procedure FailNextWrite_WholeBatch;
    [Test] procedure FailNextWrite_OnlyOnce;
    [Test] procedure WrongKind_RefusesThatDocumentOnly;
    [Test] procedure Unavailable_EveryCallRaises;
    [Test] procedure Raw_NotSupported;
    [Test] procedure EngineText_NotSupported;
    [Test] procedure SchemaKindChange_SchemaError;
    [Test] procedure Write_IndexNeverEnsured_NotFound;
    [Test] procedure Write_IndexDroppedBeforeApplied_WholeBatch;
    [Test] procedure Eq_AccentSensitive;
    [Test] procedure Relaxed_MoreWordsFirst;
    [Test] procedure Filter_ValueOfWrongKind_RequestError;
    [Test] procedure Facet_FilterableNotFacet_RequestError;
    [Test] procedure DocumentCount_AndIndexes;
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

initialization
  TDUnitX.RegisterTestFixture(TMockTests);

end.
