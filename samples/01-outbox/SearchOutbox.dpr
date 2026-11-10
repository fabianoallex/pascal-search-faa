program SearchOutbox;

(* Sample 01: a search index kept in step with the database through
   pascal-db-faa's transactional outbox (PascalSearch.Outbox, docs/guide.md
   "The outbox bridge").

   A product and the event that announces it are written in one transaction;
   pascal-db-faa's relay hands the event to its local sink, and the sink runs
   TSearchOutboxHandler, which loads the products' current rows and writes
   them to the index (a product gone is deleted from it). A product rolled
   back leaves no event, so it never reaches the index. Then a search with a
   filter, a sort and a facet, an update and a delete that follow the same
   way, and a full reindex from the database, page by page through Sync.

   The passes don't sleep or loop: a real program calls the relay's and the
   local sink's RunOnce on a timer or a worker thread, with the current Unix
   time. This sample passes the times itself, so its output is the same on
   every run and every engine.

   Settings (environment variables, all optional):
     SEARCH_SAMPLE_ENGINE        mock (default: in memory, no server),
                                 meilisearch or typesense
     SEARCH_SAMPLE_URL           default http://localhost:7700 (Meilisearch)
                                 or http://localhost:8108 (Typesense)
     SEARCH_SAMPLE_KEY           the engine's API key
     SEARCH_SAMPLE_SQLITE_CLIENT FPC: the sqlite3 library, when the default
                                 search doesn't find it (on Windows, a
                                 sqlite.org DLL of the program's bitness);
                                 Delphi's FireDAC links SQLite in
     SEARCH_SAMPLE_OUTBOX_SQL    the outbox's SQL folder; default
                                 external/pascal-db-faa/docs/outbox/sql,
                                 looked for above the program

   The database is search_outbox_sample.sqlite next to the program, created
   on every run. The outbox's tables and statements are the application's
   (pascal-db-faa's docs/outbox.md); this sample reads pascal-db-faa's
   reference SQL from its folder, where an application would copy the files
   into its own SQL folder (or resources) and run OUTBOX.SCHEMA as a
   migration.

   Same source for Delphi (SearchOutbox.dproj, FireDAC) and Lazarus/FPC
   (SearchOutbox.lpi, SQLdb). The loader and the error callback are methods:
   the callbacks are "reference to" on Delphi and "of object" on FPC 3.2.2,
   and a method compiles on both. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
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
  PascalCommon.SafeLog,
  PascalDb.Outbox,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Mock,
  PascalSearch.Meilisearch,
  PascalSearch.Typesense,
  PascalSearch.Outbox;

const
  TENANT = 'shop';
  KIND_SAVED = 'product.saved';
  KIND_DELETED = 'product.deleted';
  INDEX_NAME = 'sample_products';

type
  /// The application's side: its products table, the events it enqueues
  /// with each change, and the loader the bridge calls.
  TCatalog = class
  private
    FFactory: IDBFactory;
    procedure Exec(const ASql: string);
  public
    constructor Create(const AFactory: IDBFactory);
    procedure CreateTables;
    procedure SaveProduct(AId: Integer; const ATitle, ACategory: string; APriceCents: Integer;
      ANow: Int64; ACommit: Boolean = True);
    procedure DeleteProduct(AId: Integer; ANow: Int64);
    function ProductIds: TArray<string>;
    /// TSearchDocumentLoader: the documents of the ids that still exist.
    function LoadDocuments(const AIds: TArray<string>): TSearchDocuments;
    /// TOutboxErrorProc: a failed try (the local sink retries it later).
    procedure OnOutboxError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
  end;

function Env(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function DatabaseFile: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'search_outbox_sample.sqlite';
end;

function OutboxSqlRoot: string;
var
  LDir, LParent, LCandidate: string;
  I: Integer;
begin
  Result := GetEnvironmentVariable('SEARCH_SAMPLE_OUTBOX_SQL');
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
  raise Exception.Create('The outbox SQL folder was not found: git submodule update --init, ' +
    'or set SEARCH_SAMPLE_OUTBOX_SQL');
end;

function NewFactory: IDBFactory;
var
  LConfig: IDatabaseConfig;
begin
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := DatabaseFile;
  LConfig.ConnectionParams.Values['ClientLibrary'] := Env('SEARCH_SAMPLE_SQLITE_CLIENT', '');
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := DatabaseFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  // pascal-db-faa's layout: a folder per database, COMMON for the rest
  // (SQLite takes every outbox statement from COMMON).
  LConfig.SQLDirectory := 'SQLITE';
  LConfig.SqlSource := TFallbackSqlSource.Create(TDirectorySqlSource.Create(OutboxSqlRoot), 'COMMON');
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 3;
  {$IFDEF FPC}
  Result := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  Result := TFDFactory.Create(LConfig);
  {$ENDIF}
end;

function NewEngine(out ADescription: string): ISearchEngine;
var
  LName: string;
begin
  LName := LowerCase(Env('SEARCH_SAMPLE_ENGINE', 'mock'));
  if LName = 'meilisearch' then
  begin
    ADescription := 'Meilisearch at ' + Env('SEARCH_SAMPLE_URL', 'http://localhost:7700');
    Result := TMeilisearchEngine.New(TMeilisearchConfig.Create(
      Env('SEARCH_SAMPLE_URL', 'http://localhost:7700'), Env('SEARCH_SAMPLE_KEY', '')));
  end
  else if LName = 'typesense' then
  begin
    ADescription := 'Typesense at ' + Env('SEARCH_SAMPLE_URL', 'http://localhost:8108');
    Result := TTypesenseEngine.New(TTypesenseConfig.Create(
      Env('SEARCH_SAMPLE_URL', 'http://localhost:8108'), Env('SEARCH_SAMPLE_KEY', '')));
  end
  else if LName = 'mock' then
  begin
    ADescription := 'the in-memory mock';
    Result := TMockSearchEngine.New;
  end
  else
    raise Exception.CreateFmt('SEARCH_SAMPLE_ENGINE must be mock, meilisearch or typesense, not "%s"',
      [LName]);
end;

function Schema: ISearchSchema;
begin
  Result := TSearchSchema.New(INDEX_NAME)
    .Text('title')
    .Keyword('category', [sfFilter, sfFacet])
    .Num('price', [sfFilter, sfSort]);
end;

// Prices are cents in the database and a number in the index; printed with
// a '.', whatever the machine's locale.
function PriceText(APrice: Double): string;
var
  LCents: Int64;
begin
  LCents := Round(APrice * 100);
  Result := Format('%d.%.2d', [LCents div 100, LCents mod 100]);
end;

{ TCatalog }

constructor TCatalog.Create(const AFactory: IDBFactory);
begin
  inherited Create;
  FFactory := AFactory;
end;

procedure TCatalog.Exec(const ASql: string);
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
procedure TCatalog.CreateTables;
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
  Exec('CREATE TABLE PRODUCTS (ID INTEGER NOT NULL PRIMARY KEY, TITLE VARCHAR(100) NOT NULL, ' +
    'CATEGORY VARCHAR(40) NOT NULL, PRICE_CENTS INTEGER NOT NULL)');
end;

// The product and its event: one transaction, both or neither. The payload
// carries only the id (pascal-db-faa: keep payloads thin); the bridge reads
// the current row when it runs.
procedure TCatalog.SaveProduct(AId: Integer; const ATitle, ACategory: string;
  APriceCents: Integer; ANow: Int64; ACommit: Boolean);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'DELETE FROM PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.ExecSql;
    LQuery.Sql := 'INSERT INTO PRODUCTS (ID, TITLE, CATEGORY, PRICE_CENTS) ' +
      'VALUES (:ID, :TITLE, :CATEGORY, :PRICE_CENTS)';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['TITLE'] := ATitle;
    LQuery.Params.Strings['CATEGORY'] := ACategory;
    LQuery.Params.Integers['PRICE_CENTS'] := APriceCents;
    LQuery.ExecSql;
    // Same query, same transaction: Enqueue replaces its SQL.
    TOutbox.Enqueue(FFactory, LQuery, TENANT, KIND_SAVED, SearchOutboxPayload([IntToStr(AId)]),
      ANow);
    if ACommit then
    begin
      LScope.Commit;
      SafeWriteln('saved ' + IntToStr(AId) + ': ' + ATitle);
    end
    else
    begin
      LScope.Rollback;
      SafeWriteln('rolled back ' + IntToStr(AId) + ': ' + ATitle + ' (its event went with it)');
    end;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TCatalog.DeleteProduct(AId: Integer; ANow: Int64);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'DELETE FROM PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.ExecSql;
    TOutbox.Enqueue(FFactory, LQuery, TENANT, KIND_DELETED, SearchOutboxPayload([IntToStr(AId)]),
      ANow);
    LScope.Commit;
    SafeWriteln('deleted ' + IntToStr(AId));
  except
    LScope.Rollback;
    raise;
  end;
end;

function TCatalog.ProductIds: TArray<string>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  N: Integer;
begin
  Result := nil;
  N := 0;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := 'SELECT ID FROM PRODUCTS ORDER BY ID';
  LResult := LQuery.Open;
  while not LResult.Eof do
  begin
    SetLength(Result, N + 1);
    Result[N] := IntToStr(LResult.Integers['ID']);
    Inc(N);
    LResult.Next;
  end;
end;

// Runs outside any transaction (the local sink runs handlers outside one),
// so it reads what is committed now.
function TCatalog.LoadDocuments(const AIds: TArray<string>): TSearchDocuments;
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
    LQuery.Sql := 'SELECT TITLE, CATEGORY, PRICE_CENTS FROM PRODUCTS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := StrToInt(AIds[I]);
    LResult := LQuery.Open;
    if not LResult.Eof then
    begin
      SetLength(Result, N + 1);
      Result[N] := TSearchDocument.New(AIds[I])
        .Str('title', LResult.Strings['TITLE'])
        .Str('category', LResult.Strings['CATEGORY'])
        .Num('price', LResult.Integers['PRICE_CENTS'] / 100);
      Inc(N);
    end;
    LResult := nil;
  end;
end;

procedure TCatalog.OnOutboxError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
begin
  // AMessage is "<exception class>: <message>".
  SafeWriteln('  %s failed (attempt %d): %s', [AHandler, AEvent.Attempts + 1, AMessage]);
end;

procedure PrintSearch(const AIndex: ISearchIndex; const AText, ACategory: string);
var
  LQuery: ISearchQuery;
  LResult: ISearchResult;
  LFacet: TSearchFacet;
  LLine, LWhere: string;
  I: Integer;
begin
  LQuery := AIndex.Search(AText).OrderBy('price').Facets(['category']);
  LWhere := '';
  if ACategory <> '' then
  begin
    LQuery := LQuery.Where(F.Eq('category', ACategory));
    LWhere := ', category ' + ACategory;
  end;
  LResult := LQuery.Execute;
  SafeWriteln('search "%s"%s, by price: %d hit(s)', [AText, LWhere, LResult.Total]);
  for I := 0 to LResult.Count - 1 do
    SafeWriteln('  ' + LResult.Hit(I).Id + ' ' + LResult.Hit(I).Document.Find('title').AsString +
      ' ' + PriceText(LResult.Hit(I).Document.Find('price').AsDouble));
  if LResult.FindFacet('category', LFacet) then
  begin
    LLine := '';
    for I := 0 to High(LFacet.Values) do
      LLine := LLine + Format(' %s=%d', [LFacet.Values[I].Value, LFacet.Values[I].Count]);
    SafeWriteln('  facet category:' + LLine);
  end;
end;

procedure Run;
var
  LFactory: IDBFactory;
  LCatalog: TCatalog;
  LEngine: ISearchEngine;
  LIndex: ISearchIndex;
  LBridge: TSearchOutboxHandler;
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
  LEngineText: string;
  LIds, LPage: TArray<string>;
  LDelivered, LDone, I, J, N: Integer;
begin
  if FileExists(DatabaseFile) then
    DeleteFile(DatabaseFile);
  LFactory := NewFactory;
  LEngine := NewEngine(LEngineText);
  SafeWriteln('Database: SQLite file ' + ExtractFileName(DatabaseFile) + '; search: ' + LEngineText);
  // A fresh index on every run. An application ensures it at startup:
  // EnsureIndex brings an existing one up to the schema.
  LEngine.DropIndex(INDEX_NAME);
  LIndex := LEngine.EnsureIndex(Schema);

  LCatalog := TCatalog.Create(LFactory);
  try
    LCatalog.CreateTables;
    // The bridge is one of the local sink's handlers: the name is stored
    // with each delivery, so keep it once deliveries exist.
    LBridge := TSearchOutboxHandler.Create('search.products', LIndex, [KIND_SAVED, KIND_DELETED],
      LCatalog.LoadDocuments);
    LSink := TOutboxLocalSink.Create(LFactory, PdbOutboxNewOwner('sink'), TOutboxOptions.Default);
    LSink.SetOnError(LCatalog.OnOutboxError);
    LSink.AddHandler(LBridge);
    LRelay := TOutboxRelay.Create(LFactory, LSink, PdbOutboxNewOwner('relay'),
      TOutboxOptions.Default);
    try
      LRelay.OnError := LCatalog.OnOutboxError;
      SafeWriteln('');
      LCatalog.SaveProduct(1, 'Café com leite', 'bebida', 750, 990);
      LCatalog.SaveProduct(2, 'Café expresso', 'bebida', 500, 991);
      LCatalog.SaveProduct(3, 'Pão de queijo', 'salgado', 400, 992);
      LCatalog.SaveProduct(4, 'Café gelado', 'bebida', 900, 993, False);
      // Each pass's result goes to a variable first: the handlers may print.
      LDelivered := LRelay.RunOnce(1000);
      LDone := LSink.RunOnce(1000);
      SafeWriteln('t=1000 relay: %d event(s) delivered; local sink: %d handler run(s) done',
        [LDelivered, LDone]);
      SafeWriteln('');
      PrintSearch(LIndex, 'café', '');
      PrintSearch(LIndex, '', 'salgado');
      SafeWriteln('');

      LCatalog.SaveProduct(1, 'Café com leite', 'bebida', 450, 1001);
      LCatalog.DeleteProduct(3, 1001);
      LDelivered := LRelay.RunOnce(1002);
      LDone := LSink.RunOnce(1002);
      SafeWriteln('t=1002 relay: %d event(s) delivered; local sink: %d handler run(s) done',
        [LDelivered, LDone]);
      PrintSearch(LIndex, 'café', '');
      SafeWriteln('');

      // A full reindex (a new index, or one rebuilt after dead deliveries):
      // the application pages its ids and calls Sync. Dropping the index
      // first also removes documents whose rows are gone; it is empty while
      // it fills.
      LEngine.DropIndex(INDEX_NAME);
      LIndex := LEngine.EnsureIndex(Schema);
      LIds := LCatalog.ProductIds;
      I := 0;
      while I < Length(LIds) do
      begin
        N := Length(LIds) - I;
        if N > 100 then
          N := 100;
        SetLength(LPage, N);
        for J := 0 to N - 1 do
          LPage[J] := LIds[I + J];
        LBridge.Sync(LPage);
        Inc(I, N);
      end;
      SafeWriteln('reindexed: %d product(s)', [Length(LIds)]);
      PrintSearch(LIndex, '', '');
    finally
      LRelay.Free;
    end;
    SafeWriteln('purged: %d delivered event(s)', [TOutbox.Purge(LFactory, 2000)]);
    LSink := nil;
  finally
    LCatalog.Free;
  end;
  LEngine.DropIndex(INDEX_NAME);
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  // UTF-8 out, whatever the console's code page or a redirected stdout.
  PcSetSafeLogUtf8(True);
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    on E: Exception do
    begin
      SafeWriteln(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
