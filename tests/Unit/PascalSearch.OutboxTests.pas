unit PascalSearch.OutboxTests;

{ Tests for the outbox bridge (PascalSearch.Outbox, docs/design.md section
  11), with no database and no search engine: an outbox event is a record,
  so the tests build events and hand them to the handler, as pascal-db-faa's
  local sink would, and the index is a TMockSearchEngine's. The "database"
  is the fixture's list of rows, read by its loader method. DeferWrites
  proves the handler waits for its writes; FailNextWrite and Unavailable
  that every failure is raised to the outbox, and that the retry (Handle
  again) fixes the index. The whole path with a real outbox and engine is
  in the integration suite.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalDb.Outbox,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Interfaces,
  PascalSearch.Mock,
  PascalSearch.Outbox;

type
  [TestFixture]
  TOutboxTests = class
  private
    FEngine: IMockSearchEngine;
    FIndex: ISearchIndex;
    FBridge: TSearchOutboxHandler;
    FHandler: IOutboxHandler;
    FRowIds: TArray<string>;
    FRowTitles: TArray<string>;
    FLoads: Integer;
    FLoadedIds: string;
    FLoaderBug: Integer;
    procedure SetRow(const AId, ATitle: string);
    procedure DeleteRow(const AId: string);
    function Load(const AIds: TArray<string>): TSearchDocuments;
    function ReadCsv(const AEvent: TOutboxEvent): TArray<string>;
    function Event(const AKind, APayload: string): TOutboxEvent;
    function TitleOf(const AId: string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure Name_AsGiven;
    [Test] procedure Accepts_DeclaredKindsOnly;
    [Test] procedure Create_BadArguments_ArgumentError;
    [Test] procedure Handle_UpsertsTheRows;
    [Test] procedure Handle_RowGone_DeletesTheDocument;
    [Test] procedure Handle_UpdatedRow_ReplacesTheDocument;
    [Test] procedure Handle_WaitsForTheWrites;
    [Test] procedure Handle_IntegerIds;
    [Test] procedure Handle_SingleId;
    [Test] procedure Handle_RepeatedIdLoadedOnce;
    [Test] procedure Handle_NoIds_NothingLoaded;
    [Test] procedure Handle_BadPayload_ArgumentError;
    [Test] procedure Handle_BadId_ArgumentErrorBeforeLoading;
    [Test] procedure Handle_SomeIdsRefused_RaisesAndRetryFixes;
    [Test] procedure Handle_WholeBatchRefused_RaisesAndRetryFixes;
    [Test] procedure Handle_EngineDown_RaisesAndRetryFixes;
    [Test] procedure Loader_DocumentNotAskedFor_ArgumentError;
    [Test] procedure Loader_SameDocumentTwice_ArgumentError;
    [Test] procedure IdsReader_OtherPayload;
    [Test] procedure Sync_Reindex;
    [Test] procedure Payload_RoundTrip;
  end;

implementation

const
  KIND_SAVED = 'product.saved';
  KIND_DELETED = 'product.deleted';

function Schema: ISearchSchema;
begin
  Result := TSearchSchema.New('outbox_products').Text('title');
end;

{ TOutboxTests }

procedure TOutboxTests.Setup;
begin
  FEngine := TMockSearchEngine.New;
  FIndex := FEngine.EnsureIndex(Schema);
  FRowIds := nil;
  FRowTitles := nil;
  FLoads := 0;
  FLoadedIds := '';
  FLoaderBug := 0;
  FBridge := TSearchOutboxHandler.Create('search.products', FIndex, [KIND_SAVED, KIND_DELETED],
    Load);
  FHandler := FBridge;
end;

procedure TOutboxTests.TearDown;
begin
  FHandler := nil;
  FBridge := nil;
  FIndex := nil;
  FEngine := nil;
end;

procedure TOutboxTests.SetRow(const AId, ATitle: string);
var
  I: Integer;
begin
  for I := 0 to High(FRowIds) do
    if FRowIds[I] = AId then
    begin
      FRowTitles[I] := ATitle;
      Exit;
    end;
  SetLength(FRowIds, Length(FRowIds) + 1);
  SetLength(FRowTitles, Length(FRowTitles) + 1);
  FRowIds[High(FRowIds)] := AId;
  FRowTitles[High(FRowTitles)] := ATitle;
end;

procedure TOutboxTests.DeleteRow(const AId: string);
var
  I, J: Integer;
begin
  for I := 0 to High(FRowIds) do
    if FRowIds[I] = AId then
    begin
      for J := I to High(FRowIds) - 1 do
      begin
        FRowIds[J] := FRowIds[J + 1];
        FRowTitles[J] := FRowTitles[J + 1];
      end;
      SetLength(FRowIds, Length(FRowIds) - 1);
      SetLength(FRowTitles, Length(FRowTitles) - 1);
      Exit;
    end;
end;

// The application's loader: the documents of the rows that exist.
function TOutboxTests.Load(const AIds: TArray<string>): TSearchDocuments;
var
  I, J, N: Integer;
begin
  Inc(FLoads);
  FLoadedIds := '';
  Result := nil;
  N := 0;
  for I := 0 to High(AIds) do
  begin
    if FLoadedIds <> '' then
      FLoadedIds := FLoadedIds + ',';
    FLoadedIds := FLoadedIds + AIds[I];
    for J := 0 to High(FRowIds) do
      if FRowIds[J] = AIds[I] then
      begin
        SetLength(Result, N + 1);
        Result[N] := TSearchDocument.New(FRowIds[J]).Str('title', FRowTitles[J]);
        Inc(N);
      end;
  end;
  if FLoaderBug = 1 then
  begin
    SetLength(Result, N + 1);
    Result[N] := TSearchDocument.New('99').Str('title', 'not asked for');
  end
  else if (FLoaderBug = 2) and (N > 0) then
  begin
    SetLength(Result, N + 1);
    Result[N] := Result[0];
  end;
end;

function TOutboxTests.ReadCsv(const AEvent: TOutboxEvent): TArray<string>;
var
  LText: string;
  P, N: Integer;
begin
  Result := nil;
  N := 0;
  LText := AEvent.Payload + ',';
  P := Pos(',', LText);
  while P > 0 do
  begin
    SetLength(Result, N + 1);
    Result[N] := Copy(LText, 1, P - 1);
    Inc(N);
    Delete(LText, 1, P);
    P := Pos(',', LText);
  end;
end;

function TOutboxTests.Event(const AKind, APayload: string): TOutboxEvent;
begin
  Result.TenantId := 'shop';
  Result.Id := '0123456789abcdef0123456789abcdef';
  Result.Kind := AKind;
  Result.Payload := APayload;
  Result.TraceParent := '';
  Result.CreatedAt := 1000;
  Result.Attempts := 0;
end;

function TOutboxTests.TitleOf(const AId: string): string;
var
  LHit: ISearchHit;
begin
  LHit := FIndex.Get(AId);
  if LHit = nil then
    Result := '(none)'
  else
    Result := LHit.Document.Find('title').AsString;
end;

procedure TOutboxTests.Name_AsGiven;
begin
  TAssert.AssertEquals('search.products', FHandler.Name);
end;

procedure TOutboxTests.Accepts_DeclaredKindsOnly;
begin
  TAssert.AssertTrue(FHandler.Accepts(KIND_SAVED));
  TAssert.AssertTrue(FHandler.Accepts(KIND_DELETED));
  TAssert.AssertFalse(FHandler.Accepts('order.placed'));
  TAssert.AssertFalse('kinds are compared exactly', FHandler.Accepts('Product.Saved'));
end;

procedure TOutboxTests.Create_BadArguments_ArgumentError;
var
  LCases, I: Integer;
  LHandler: IOutboxHandler;
begin
  LCases := 0;
  for I := 1 to 4 do
    try
      case I of
        1: LHandler := TSearchOutboxHandler.Create('', FIndex, [KIND_SAVED], Load);
        2: LHandler := TSearchOutboxHandler.Create(StringOfChar('h', 61), FIndex, [KIND_SAVED], Load);
        3: LHandler := TSearchOutboxHandler.Create('search', nil, [KIND_SAVED], Load);
        4: LHandler := TSearchOutboxHandler.Create('search', FIndex, [], Load);
      end;
      TAssert.Fail(Format('case %d must raise ESearchArgumentError', [I]));
    except
      on E: ESearchArgumentError do
        Inc(LCases);
    end;
  TAssert.AssertEquals(4, LCases);
  LHandler := TSearchOutboxHandler.Create(StringOfChar('h', 60), FIndex, [KIND_SAVED], Load);
  TAssert.AssertEquals(60, Integer(Length(LHandler.Name)));
end;

procedure TOutboxTests.Handle_UpsertsTheRows;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
  TAssert.AssertEquals(2, FEngine.DocumentCount('outbox_products'));
  TAssert.AssertEquals('Café', TitleOf('1'));
  TAssert.AssertEquals('Água', TitleOf('2'));
  TAssert.AssertEquals('one load for the event', 1, FLoads);
end;

procedure TOutboxTests.Handle_RowGone_DeletesTheDocument;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
  DeleteRow('2');
  FHandler.Handle(Event(KIND_DELETED, '{"ids":["2"]}'));
  TAssert.AssertEquals(1, FEngine.DocumentCount('outbox_products'));
  TAssert.AssertEquals('(none)', TitleOf('2'));
  TAssert.AssertEquals('Café', TitleOf('1'));
  // The kind doesn't decide: a "saved" event for a row gone deletes too, and
  // a "deleted" event for a row that is back writes it.
  SetRow('2', 'Água de novo');
  FHandler.Handle(Event(KIND_DELETED, '{"ids":["2"]}'));
  TAssert.AssertEquals('Água de novo', TitleOf('2'));
  DeleteRow('1');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
  TAssert.AssertEquals('(none)', TitleOf('1'));
end;

procedure TOutboxTests.Handle_UpdatedRow_ReplacesTheDocument;
begin
  SetRow('1', 'Café');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
  SetRow('1', 'Café com leite');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
  TAssert.AssertEquals(1, FEngine.DocumentCount('outbox_products'));
  TAssert.AssertEquals('Café com leite', TitleOf('1'));
end;

procedure TOutboxTests.Handle_WaitsForTheWrites;
begin
  // Under DeferWrites a write is applied only by its WaitFor: a handler that
  // didn't wait would leave both writes pending.
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
  FEngine.DeferWrites := True;
  DeleteRow('2');
  SetRow('3', 'Chá');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["2","3"]}'));
  TAssert.AssertEquals(0, FEngine.PendingWrites);
  TAssert.AssertEquals('Chá', TitleOf('3'));
  TAssert.AssertEquals('(none)', TitleOf('2'));
end;

procedure TOutboxTests.Handle_IntegerIds;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":[1,2],"version":7}'));
  TAssert.AssertEquals('1,2', FLoadedIds);
  TAssert.AssertEquals(2, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Handle_SingleId;
begin
  SetRow('7', 'Café');
  FHandler.Handle(Event(KIND_SAVED, '{"id":7}'));
  TAssert.AssertEquals('7', FLoadedIds);
  TAssert.AssertEquals('Café', TitleOf('7'));
  FHandler.Handle(Event(KIND_SAVED, '{"id":"7"}'));
  TAssert.AssertEquals('7', FLoadedIds);
end;

procedure TOutboxTests.Handle_RepeatedIdLoadedOnce;
begin
  SetRow('1', 'Café');
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1",1,"2","1"]}'));
  TAssert.AssertEquals('1,2', FLoadedIds);
  TAssert.AssertEquals(1, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Handle_NoIds_NothingLoaded;
begin
  FHandler.Handle(Event(KIND_SAVED, '{"ids":[]}'));
  TAssert.AssertEquals(0, FLoads);
end;

procedure TOutboxTests.Handle_BadPayload_ArgumentError;
const
  PAYLOADS: array[0..6] of string = ('', 'not json', '[1,2]', '{"other":1}', '{"ids":"1"}',
    '{"ids":[true]}', '{"id":1.5}');
var
  I, LRaised: Integer;
begin
  LRaised := 0;
  for I := 0 to High(PAYLOADS) do
    try
      FHandler.Handle(Event(KIND_SAVED, PAYLOADS[I]));
      TAssert.Fail('must raise ESearchArgumentError: ' + PAYLOADS[I]);
    except
      on E: ESearchArgumentError do
        Inc(LRaised);
    end;
  TAssert.AssertEquals(Integer(Length(PAYLOADS)), LRaised);
  TAssert.AssertEquals('nothing loaded', 0, FLoads);
end;

procedure TOutboxTests.Handle_BadId_ArgumentErrorBeforeLoading;
begin
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","a.b"]}'));
    TAssert.Fail('must raise ESearchArgumentError');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('a.b', E.Message) > 0);
  end;
  TAssert.AssertEquals('nothing loaded', 0, FLoads);
end;

procedure TOutboxTests.Handle_SomeIdsRefused_RaisesAndRetryFixes;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FEngine.FailNextWrite(['2'], 'bad document');
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
    TAssert.Fail('must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertFalse(E.WholeBatch);
      TAssert.AssertEquals('2', E.Failures[0].Id);
    end;
  end;
  TAssert.AssertEquals('the other one was written', 'Café', TitleOf('1'));
  // The outbox's next try: the same event again.
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
  TAssert.AssertEquals('Água', TitleOf('2'));
  TAssert.AssertEquals(2, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Handle_WholeBatchRefused_RaisesAndRetryFixes;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FEngine.FailNextWrite([], 'task failed', True);
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
    TAssert.Fail('must raise ESearchWriteFailed');
  except
    on E: ESearchWriteFailed do
      TAssert.AssertTrue(E.WholeBatch);
  end;
  TAssert.AssertEquals(0, FEngine.DocumentCount('outbox_products'));
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1","2"]}'));
  TAssert.AssertEquals(2, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Handle_EngineDown_RaisesAndRetryFixes;
begin
  SetRow('1', 'Café');
  FEngine.Unavailable := True;
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
    TAssert.Fail('must raise ESearchUnavailable');
  except
    on E: ESearchUnavailable do
      ;
  end;
  FEngine.Unavailable := False;
  TAssert.AssertEquals(0, FEngine.DocumentCount('outbox_products'));
  FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
  TAssert.AssertEquals('Café', TitleOf('1'));
end;

procedure TOutboxTests.Loader_DocumentNotAskedFor_ArgumentError;
begin
  SetRow('1', 'Café');
  FLoaderBug := 1;
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
    TAssert.Fail('must raise ESearchArgumentError');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('"99"', E.Message) > 0);
  end;
  TAssert.AssertEquals('nothing written', 0, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Loader_SameDocumentTwice_ArgumentError;
begin
  SetRow('1', 'Café');
  FLoaderBug := 2;
  try
    FHandler.Handle(Event(KIND_SAVED, '{"ids":["1"]}'));
    TAssert.Fail('must raise ESearchArgumentError');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('twice', E.Message) > 0);
  end;
  TAssert.AssertEquals('nothing written', 0, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.IdsReader_OtherPayload;
begin
  SetRow('1', 'Café');
  SetRow('2', 'Água');
  FBridge.IdsReader := ReadCsv;
  FHandler.Handle(Event(KIND_SAVED, '1,2'));
  TAssert.AssertEquals('1,2', FLoadedIds);
  TAssert.AssertEquals(2, FEngine.DocumentCount('outbox_products'));
end;

procedure TOutboxTests.Sync_Reindex;
var
  I, J: Integer;
  LPage: TArray<string>;
begin
  // A full reindex: the application pages its ids and calls Sync.
  for I := 1 to 25 do
    SetRow(IntToStr(I), 'Produto ' + IntToStr(I));
  SetLength(LPage, 10);
  for I := 0 to 2 do
  begin
    if I = 2 then
      SetLength(LPage, 5);
    for J := 0 to High(LPage) do
      LPage[J] := IntToStr(I * 10 + J + 1);
    FBridge.Sync(LPage);
  end;
  TAssert.AssertEquals(25, FEngine.DocumentCount('outbox_products'));
  TAssert.AssertEquals('Produto 25', TitleOf('25'));
end;

procedure TOutboxTests.Payload_RoundTrip;
var
  LIds: TArray<string>;
begin
  TAssert.AssertEquals('{"ids":["1","a-b_c"]}', SearchOutboxPayload(['1', 'a-b_c']));
  LIds := SearchOutboxIds(SearchOutboxPayload(['1', 'a-b_c']));
  TAssert.AssertEquals(2, Integer(Length(LIds)));
  TAssert.AssertEquals('a-b_c', LIds[1]);
  TAssert.AssertEquals('{"ids":[]}', SearchOutboxPayload([]));
end;

initialization
  TDUnitX.RegisterTestFixture(TOutboxTests);

end.
