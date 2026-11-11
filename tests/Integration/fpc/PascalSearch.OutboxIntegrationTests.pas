unit PascalSearch.OutboxIntegrationTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Integration/PascalSearch.OutboxIntegrationTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ The outbox bridge end to end, on the engine the contract suite runs on
  (SEARCH_CONTRACT_ENGINE) and a SQLite database through pascal-db-faa
  (SQLdb on FPC, FireDAC on Delphi): a product and its event written in one
  transaction, pascal-db-faa's relay and local sink, TSearchOutboxHandler,
  the index. The unit suite covers the handler's every branch on the mock;
  here the pieces meet for real:

  - committed changes reach the index, a rolled-back one doesn't, and an
    update and a delete later follow;
  - a failed try (an index not there yet) leaves the delivery pending, and
    the local sink's retry, after the delay, delivers it;
  - a caller's bug (an id the library refuses) is dead at the first try
    (EOutboxGiveUp, pascal-db-faa 0.21.0; design S30);
  - a reindex from the database, page by page through Sync.

  The outbox's tables and statements are pascal-db-faa's reference SQL, read
  from external/pascal-db-faa/docs/outbox/sql (SEARCH_OUTBOX_SQL to put it
  elsewhere): nothing is copied. The database is a file next to the runner,
  deleted before and after each test. On FPC, SQLdb loads sqlite3 from the
  default search path, or SEARCH_SQLITE_CLIENT (on Windows, a 64-bit
  sqlite.org DLL for a 64-bit runner); FireDAC links SQLite into the
  program.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Integration/fpc is
  generated from the master by tools/gen_fpc_mirror.py: edit only the
  master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Classes,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalDb.Outbox,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Interfaces,
  PascalSearch.Outbox,
  PascalSearch.IntegrationEnv;

type
  TOutboxIntegrationTests = class(TTestCase)
  private
    FFactory: IDBFactory;
    FEngine: ISearchEngine;
    FIndex: ISearchIndex;
    FErrors: Integer;
    FLastError: string;
    function DatabaseFile: string;
    procedure DeleteDatabase;
    function NewFactory: IDBFactory;
    procedure Exec(const ASql: string);
    procedure CreateTables;
    procedure SaveProduct(AId: Integer; const ATitle: string; ANow: Int64; ACommit: Boolean = True);
    procedure DeleteProduct(AId: Integer; ANow: Int64);
    procedure InsertWithoutEvent(AId: Integer; const ATitle: string);
    procedure EnqueuePayload(const APayload: string; ANow: Int64);
    function DeliveriesWithStatus(const AStatus: string): Integer;
    function AllProductIds: TArray<string>;
    function Load(const AIds: TArray<string>): TSearchDocuments;
    procedure OnOutboxError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
    function TitleOf(const AId: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CommittedChanges_ReachTheIndex;
    procedure FailedTry_RetriedByTheLocalSink;
    procedure BadId_DeadAtTheFirstTry;
    procedure Reindex_FromTheDatabase;
  end;

implementation

const
  INDEX_NAME = 'it_outbox_products';
  MISSING_INDEX_NAME = 'it_outbox_later';
  KIND_SAVED = 'product.saved';
  KIND_DELETED = 'product.deleted';
  TENANT = 'it';

function Schema(const AName: string): ISearchSchema;
begin
  Result := TSearchSchema.New(AName).Text('title');
end;

function OutboxSqlRoot: string;
var
  LDir, LParent, LCandidate: string;
  I: Integer;
begin
  Result := GetEnvironmentVariable('SEARCH_OUTBOX_SQL');
  if Result <> '' then
    Exit;
  LDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  for I := 1 to 8 do
  begin
    LCandidate := IncludeTrailingPathDelimiter(LDir) + 'external' + PathDelim + 'pascal-db-faa' +
      PathDelim + 'docs' + PathDelim + 'outbox' + PathDelim + 'sql';
    if DirectoryExists(LCandidate) then
      Exit(LCandidate);
    LParent := ExcludeTrailingPathDelimiter(ExtractFilePath(LDir));
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  raise Exception.Create('external/pascal-db-faa/docs/outbox/sql not found above the runner: ' +
    'git submodule update --init, or set SEARCH_OUTBOX_SQL');
end;

function TOutboxIntegrationTests.DatabaseFile: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'pascalsearch_it_outbox.sqlite';
end;

procedure TOutboxIntegrationTests.DeleteDatabase;
const
  SUFFIXES: array[0..3] of string = ('', '-journal', '-wal', '-shm');
var
  I: Integer;
begin
  for I := 0 to High(SUFFIXES) do
    if FileExists(DatabaseFile + SUFFIXES[I]) then
      DeleteFile(DatabaseFile + SUFFIXES[I]);
end;

function TOutboxIntegrationTests.NewFactory: IDBFactory;
var
  LConfig: IDatabaseConfig;
begin
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := DatabaseFile;
  LConfig.ConnectionParams.Values['ClientLibrary'] := GetEnvironmentVariable('SEARCH_SQLITE_CLIENT');
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := DatabaseFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  // pascal-db-faa's layout: SQLite takes every statement from COMMON.
  LConfig.SQLDirectory := 'SQLITE';
  LConfig.SqlSource := TFallbackSqlSource.Create(TDirectorySqlSource.Create(OutboxSqlRoot), 'COMMON');
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 3;
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  {$IFDEF FPC}
  Result := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  Result := TFDFactory.Create(LConfig);
  {$ENDIF}
end;

procedure TOutboxIntegrationTests.Exec(const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// OUTBOX.SCHEMA split at ';', as a migration with that terminator would.
procedure TOutboxIntegrationTests.CreateTables;
var
  LScript: string;
  P: Integer;
begin
  LScript := FFactory.SqlLoader['OUTBOX.SCHEMA'].SQL;
  P := Pos(';', LScript);
  while P > 0 do
  begin
    if Trim(Copy(LScript, 1, P - 1)) <> '' then
      Exec(Copy(LScript, 1, P - 1));
    Delete(LScript, 1, P);
    P := Pos(';', LScript);
  end;
  if Trim(LScript) <> '' then
    Exec(LScript);
  Exec('CREATE TABLE IT_PRODUCTS (ID INTEGER NOT NULL PRIMARY KEY, TITLE VARCHAR(100) NOT NULL)');
end;

// The product and its event in one transaction.
procedure TOutboxIntegrationTests.SaveProduct(AId: Integer; const ATitle: string; ANow: Int64;
  ACommit: Boolean);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'DELETE FROM IT_PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.ExecSql;
    LQuery.Sql := 'INSERT INTO IT_PRODUCTS (ID, TITLE) VALUES (:ID, :TITLE)';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['TITLE'] := ATitle;
    LQuery.ExecSql;
    TOutbox.Enqueue(FFactory, LQuery, TENANT, KIND_SAVED, SearchOutboxPayload([IntToStr(AId)]),
      ANow);
    if ACommit then
      LScope.Commit
    else
      LScope.Rollback;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TOutboxIntegrationTests.DeleteProduct(AId: Integer; ANow: Int64);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'DELETE FROM IT_PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.ExecSql;
    TOutbox.Enqueue(FFactory, LQuery, TENANT, KIND_DELETED, SearchOutboxPayload([IntToStr(AId)]),
      ANow);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TOutboxIntegrationTests.InsertWithoutEvent(AId: Integer; const ATitle: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO IT_PRODUCTS (ID, TITLE) VALUES (:ID, :TITLE)';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['TITLE'] := ATitle;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// An event with any payload, alone in its transaction.
procedure TOutboxIntegrationTests.EnqueuePayload(const APayload: string; ANow: Int64);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TOutbox.Enqueue(FFactory, LQuery, TENANT, KIND_SAVED, APayload, ANow);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TOutboxIntegrationTests.DeliveriesWithStatus(const AStatus: string): Integer;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := 'SELECT COUNT(*) AS N FROM OUTBOX_DELIVERIES WHERE STATUS = :STATUS';
  LQuery.Params.Strings['STATUS'] := AStatus;
  LResult := LQuery.Open;
  Result := LResult.Integers['N'];
end;

function TOutboxIntegrationTests.AllProductIds: TArray<string>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  N: Integer;
begin
  Result := nil;
  N := 0;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := 'SELECT ID FROM IT_PRODUCTS ORDER BY ID';
  LResult := LQuery.Open;
  while not LResult.Eof do
  begin
    SetLength(Result, N + 1);
    Result[N] := IntToStr(LResult.Integers['ID']);
    Inc(N);
    LResult.Next;
  end;
end;

// The application's loader: reads the rows' current state, outside any
// transaction (the local sink runs handlers outside one).
function TOutboxIntegrationTests.Load(const AIds: TArray<string>): TSearchDocuments;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  for I := 0 to High(AIds) do
  begin
    LQuery.Sql := 'SELECT ID, TITLE FROM IT_PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := StrToInt(AIds[I]);
    LResult := LQuery.Open;
    if not LResult.Eof then
    begin
      SetLength(Result, N + 1);
      Result[N] := TSearchDocument.New(AIds[I]).Str('title', LResult.Strings['TITLE']);
      Inc(N);
    end;
    LResult := nil;
  end;
end;

procedure TOutboxIntegrationTests.OnOutboxError(const AEvent: TOutboxEvent;
  const AHandler, AMessage: string);
begin
  Inc(FErrors);
  FLastError := AMessage;
end;

function TOutboxIntegrationTests.TitleOf(const AId: string): string;
var
  LHit: ISearchHit;
begin
  LHit := FIndex.Get(AId);
  if LHit = nil then
    Result := '(none)'
  else
    Result := LHit.Document.Find('title').AsString;
end;

procedure TOutboxIntegrationTests.Setup;
begin
  FErrors := 0;
  FLastError := '';
  DeleteDatabase;
  FFactory := NewFactory;
  CreateTables;
  FEngine := IntegrationContractEngine;
  FEngine.DropIndex(INDEX_NAME);
  FEngine.DropIndex(MISSING_INDEX_NAME);
  FIndex := FEngine.EnsureIndex(Schema(INDEX_NAME));
end;

procedure TOutboxIntegrationTests.TearDown;
begin
  FIndex := nil;
  if FEngine <> nil then
    try
      FEngine.DropIndex(INDEX_NAME);
      FEngine.DropIndex(MISSING_INDEX_NAME);
    except
      // the engine is gone: the next run drops them
    end;
  FEngine := nil;
  FFactory := nil;
  DeleteDatabase;
end;

procedure TOutboxIntegrationTests.CommittedChanges_ReachTheIndex;
var
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
  LResult: ISearchResult;
begin
  LSink := TOutboxLocalSink.Create(FFactory, PdbOutboxNewOwner('sink'), TOutboxOptions.Default);
  LSink.SetOnError(OnOutboxError);
  LSink.AddHandler(TSearchOutboxHandler.Create('search.products', FIndex,
    [KIND_SAVED, KIND_DELETED], Load));
  LRelay := TOutboxRelay.Create(FFactory, LSink, PdbOutboxNewOwner('relay'), TOutboxOptions.Default);
  try
    LRelay.OnError := OnOutboxError;
    SaveProduct(1, 'Café com leite', 990);
    SaveProduct(2, 'Água com gás', 991);
    SaveProduct(3, 'Chá preto', 992, False);
    TAssert.AssertEquals('events delivered', 2, LRelay.RunOnce(1000));
    TAssert.AssertEquals('handler runs done', 2, LSink.RunOnce(1000));
    TAssert.AssertEquals(FLastError, 0, FErrors);

    LResult := FIndex.Search('café').Execute;
    TAssert.AssertEquals(1, Integer(LResult.Total));
    TAssert.AssertEquals('1', LResult.Hit(0).Id);
    TAssert.AssertEquals('Água com gás', TitleOf('2'));
    TAssert.AssertEquals('rolled back: no event', '(none)', TitleOf('3'));

    SaveProduct(1, 'Café expresso', 1001);
    DeleteProduct(2, 1001);
    TAssert.AssertEquals(2, LRelay.RunOnce(1002));
    TAssert.AssertEquals(2, LSink.RunOnce(1002));
    TAssert.AssertEquals(FLastError, 0, FErrors);
    TAssert.AssertEquals('Café expresso', TitleOf('1'));
    TAssert.AssertEquals('(none)', TitleOf('2'));
    TAssert.AssertEquals(1, Integer(FIndex.Search('').Execute.Total));
  finally
    LRelay.Free;
  end;
end;

procedure TOutboxIntegrationTests.FailedTry_RetriedByTheLocalSink;
var
  LOptions: TOutboxOptions;
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
begin
  LOptions := TOutboxOptions.Default;
  LOptions.Retry.BaseSeconds := 5;
  LSink := TOutboxLocalSink.Create(FFactory, PdbOutboxNewOwner('sink'), LOptions);
  LSink.SetOnError(OnOutboxError);
  // Bound to an index nobody ensured yet: the first try fails.
  LSink.AddHandler(TSearchOutboxHandler.Create('search.later', FEngine.Index(MISSING_INDEX_NAME),
    [KIND_SAVED], Load));
  LRelay := TOutboxRelay.Create(FFactory, LSink, PdbOutboxNewOwner('relay'), LOptions);
  try
    SaveProduct(1, 'Café com leite', 990);
    TAssert.AssertEquals(1, LRelay.RunOnce(1000));
    TAssert.AssertEquals(0, LSink.RunOnce(1000));
    TAssert.AssertEquals(1, FErrors);
    TAssert.AssertTrue(FLastError, Pos('ESearchIndexNotFound', FLastError) = 1);

    FEngine.EnsureIndex(Schema(MISSING_INDEX_NAME));
    TAssert.AssertEquals('the retry waits its delay', 0, LSink.RunOnce(1002));
    TAssert.AssertEquals(1, LSink.RunOnce(1005));
    TAssert.AssertEquals(1, FErrors);
    TAssert.AssertTrue(FEngine.Index(MISSING_INDEX_NAME).Get('1') <> nil);
  finally
    LRelay.Free;
  end;
end;

procedure TOutboxIntegrationTests.BadId_DeadAtTheFirstTry;
var
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
begin
  LSink := TOutboxLocalSink.Create(FFactory, PdbOutboxNewOwner('sink'), TOutboxOptions.Default);
  LSink.SetOnError(OnOutboxError);
  LSink.AddHandler(TSearchOutboxHandler.Create('search.products', FIndex, [KIND_SAVED], Load));
  LRelay := TOutboxRelay.Create(FFactory, LSink, PdbOutboxNewOwner('relay'), TOutboxOptions.Default);
  try
    EnqueuePayload('{"ids":["a.b"]}', 990);
    TAssert.AssertEquals(1, LRelay.RunOnce(1000));
    TAssert.AssertEquals(0, LSink.RunOnce(1000));
    TAssert.AssertEquals(1, FErrors);
    TAssert.AssertTrue(FLastError, Pos('EOutboxGiveUp: ESearchArgumentError: ', FLastError) = 1);
    TAssert.AssertEquals('dead without the 10 tries', 1, DeliveriesWithStatus('dead'));
    TAssert.AssertEquals('never tried again', 0, LSink.RunOnce(100000));
    TAssert.AssertEquals(1, FErrors);
  finally
    LRelay.Free;
  end;
end;

procedure TOutboxIntegrationTests.Reindex_FromTheDatabase;
var
  LHandler: TSearchOutboxHandler;
  LKeep: IOutboxHandler;
  LIds, LPage: TArray<string>;
  I, J, N: Integer;
begin
  for I := 1 to 7 do
    InsertWithoutEvent(I, 'Produto ' + IntToStr(I));
  LHandler := TSearchOutboxHandler.Create('search.products', FIndex, [KIND_SAVED], Load);
  LKeep := LHandler;
  // Pages of 3 ids, as an application would read them.
  LIds := AllProductIds;
  I := 0;
  while I < Length(LIds) do
  begin
    N := Length(LIds) - I;
    if N > 3 then
      N := 3;
    SetLength(LPage, N);
    for J := 0 to N - 1 do
      LPage[J] := LIds[I + J];
    LHandler.Sync(LPage);
    Inc(I, N);
  end;
  TAssert.AssertEquals(7, Integer(FIndex.Search('').Execute.Total));
  TAssert.AssertEquals('Produto 7', TitleOf('7'));
end;

initialization
  RegisterTest(TOutboxIntegrationTests);

end.
