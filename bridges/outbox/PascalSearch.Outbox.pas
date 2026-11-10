unit PascalSearch.Outbox;

{$I pascalsearch.inc}

(* Keeps a search index in step with the database through pascal-db-faa's
   transactional outbox (its docs/outbox.md; docs/design.md, section 11).

   The application enqueues an event with the ids it changed, in the
   transaction that changed them; the relay hands it to the local sink, and
   the sink runs this handler outside any transaction:

     TOutbox.Enqueue(LFactory, LQuery, LTenant, 'product.saved',
       SearchOutboxPayload([IntToStr(LId)]), LNow);
     ...
     LSink.AddHandler(TSearchOutboxHandler.Create('search.products',
       LEngine.Index('products'), ['product.saved', 'product.deleted'],
       LCatalog.LoadSearchDocuments));

   - The payload is {"ids":[...]} or {"id":...}, each id a string or an
     integer (an integer becomes its decimal text). IdsReader takes any other
     payload. Ids are checked (PascalSearch.Errors) before anything is
     loaded; a repeated id is loaded once.
   - The loader receives the ids and returns the documents of those that
     exist; an id with no document is deleted from the index. The event's
     kind doesn't choose between writing and deleting, so events handled out
     of order still end in the database's current state. A document the
     loader wasn't asked for, or one it returned twice, raises
     ESearchArgumentError.
   - Sync(Ids) is the work: load, upsert the documents found, delete the
     other ids, then wait for both writes (WaitTimeoutMs; 0: the engine's
     default). Handle reads the ids and calls it. A full reindex is the
     application's loop over its ids, calling Sync.
   - Every error is raised, so the local sink tries the delivery again later
     and marks it dead after MaxAttempts. A retry reloads and rewrites every
     id of the event: upsert and delete are idempotent, so a write that
     partly went through (Typesense) or got no answer (ESearchUnavailable;
     the adapters never send a write twice) is simply done again.
   - Run one sink worker for an index: two loading and writing the same ids
     in parallel could write an older state after a newer one.

   TSearchDocumentLoader and TSearchOutboxIdsReader are "reference to" on
   Delphi and "of object" on FPC 3.2.2 (PASCALSEARCH_FUNCREFS): a method
   compiles on both. Needs pascal-db-faa 0.18.0 or later. *)

interface

uses
  SysUtils,
  PascalDb.Version,
  PascalDb.Outbox,
  PascalSearch.Documents,
  PascalSearch.Interfaces;

type
  /// Returns the documents of the ids that exist, in any order; the ids left
  /// out are deleted from the index.
  TSearchDocumentLoader = {$IFDEF PASCALSEARCH_FUNCREFS}reference to function(
    const AIds: TArray<string>): TSearchDocuments
    {$ELSE}function(const AIds: TArray<string>): TSearchDocuments of object{$ENDIF};

  /// Reads the ids out of an event, for a payload other than the default.
  TSearchOutboxIdsReader = {$IFDEF PASCALSEARCH_FUNCREFS}reference to function(
    const AEvent: TOutboxEvent): TArray<string>
    {$ELSE}function(const AEvent: TOutboxEvent): TArray<string> of object{$ENDIF};

  /// An IOutboxHandler (pascal-db-faa's local sink) that writes the current
  /// state of an event's ids to a search index.
  TSearchOutboxHandler = class(TInterfacedObject, IOutboxHandler)
  private
    FName: string;
    FIndex: ISearchIndex;
    FKinds: TArray<string>;
    FLoader: TSearchDocumentLoader;
    FIdsReader: TSearchOutboxIdsReader;
    FWaitTimeoutMs: Integer;
  public
    /// AName is stored by the outbox with each delivery (1-60 characters):
    /// keep it once deliveries exist. AKinds: the event kinds handled.
    constructor Create(const AName: string; const AIndex: ISearchIndex;
      const AKinds: array of string; const ALoader: TSearchDocumentLoader);
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    /// Reads the event's ids and calls Sync. Raises to fail this try.
    procedure Handle(const AEvent: TOutboxEvent);
    /// Loads AIds, upserts the documents found, deletes the other ids and
    /// waits for both writes. Also the step of a full reindex.
    procedure Sync(const AIds: array of string);
    property SearchIndex: ISearchIndex read FIndex;
    /// nil: SearchOutboxIds on the payload.
    property IdsReader: TSearchOutboxIdsReader read FIdsReader write FIdsReader;
    /// Each WaitFor's limit; 0: the engine's default.
    property WaitTimeoutMs: Integer read FWaitTimeoutMs write FWaitTimeoutMs;
  end;

const
  /// The longest handler name OUTBOX_DELIVERIES.HANDLER keeps.
  SEARCH_OUTBOX_MAX_NAME = 60;

/// The ids of a payload {"ids":[...]} or {"id":...}: strings, or integers
/// written as decimal text. Anything else raises ESearchArgumentError.
function SearchOutboxIds(const APayload: string): TArray<string>;

/// The payload {"ids":[...]} for AIds, for TOutbox.Enqueue.
function SearchOutboxPayload(const AIds: array of string): string;

implementation

uses
  PascalJsonMapper.Json,
  PascalSearch.Errors;

{$IF PASCALDB_VERSION < 1800}
  {$MESSAGE FATAL 'pascal-search-faa''s outbox bridge needs pascal-db-faa 0.18.0 or later (PascalDb.Outbox)'}
{$IFEND}

function IdOf(AValue: TJsonValue): string;
var
  LInt: Int64;
begin
  case AValue.Kind of
    jkString:
      Result := AValue.AsString;
    jkNumber:
      if AValue.TryAsInt64(LInt) then
        Result := IntToStr(LInt)
      else
        raise ESearchArgumentError.CreateFmt(
          'SearchOutboxIds: the id %s is not an integer.', [AValue.NumberText]);
  else
    raise ESearchArgumentError.Create(
      'SearchOutboxIds: an id must be a string or an integer.');
  end;
end;

function SearchOutboxIds(const APayload: string): TArray<string>;
var
  LRoot, LIds, LId: TJsonValue;
  I: Integer;
begin
  try
    LRoot := ParseJson(APayload);
  except
    on E: EJsonError do
      raise ESearchArgumentError.Create('SearchOutboxIds: the payload is not JSON: ' + E.Message);
  end;
  try
    if LRoot.Kind <> jkObject then
      raise ESearchArgumentError.Create('SearchOutboxIds: the payload is not a JSON object.');
    LIds := LRoot.Find('ids');
    if LIds <> nil then
    begin
      if LIds.Kind <> jkArray then
        raise ESearchArgumentError.Create('SearchOutboxIds: "ids" is not an array.');
      SetLength(Result, LIds.Count);
      for I := 0 to LIds.Count - 1 do
        Result[I] := IdOf(LIds[I]);
      Exit;
    end;
    LId := LRoot.Find('id');
    if LId = nil then
      raise ESearchArgumentError.Create('SearchOutboxIds: the payload has no "ids" or "id".');
    SetLength(Result, 1);
    Result[0] := IdOf(LId);
  finally
    LRoot.Free;
  end;
end;

function SearchOutboxPayload(const AIds: array of string): string;
var
  LRoot, LIds: TJsonValue;
  I: Integer;
begin
  LRoot := TJsonValue.CreateObject;
  try
    LIds := TJsonValue.CreateArray;
    LRoot.AddPair('ids', LIds);
    for I := 0 to High(AIds) do
      LIds.Add(TJsonValue.CreateString(AIds[I]));
    Result := LRoot.ToJson;
  finally
    LRoot.Free;
  end;
end;

function IndexOfText(const AList: TArray<string>; ACount: Integer; const AText: string): Integer;
var
  I: Integer;
begin
  for I := 0 to ACount - 1 do
    if AList[I] = AText then
      Exit(I);
  Result := -1;
end;

{ TSearchOutboxHandler }

constructor TSearchOutboxHandler.Create(const AName: string; const AIndex: ISearchIndex;
  const AKinds: array of string; const ALoader: TSearchDocumentLoader);
var
  I: Integer;
begin
  inherited Create;
  if (AName = '') or (Length(AName) > SEARCH_OUTBOX_MAX_NAME) then
    raise ESearchArgumentError.CreateFmt(
      'TSearchOutboxHandler: the name must have 1 to %d characters.', [SEARCH_OUTBOX_MAX_NAME]);
  if AIndex = nil then
    raise ESearchArgumentError.Create('TSearchOutboxHandler: no index.');
  if Length(AKinds) = 0 then
    raise ESearchArgumentError.Create('TSearchOutboxHandler: no event kinds.');
  if not Assigned(ALoader) then
    raise ESearchArgumentError.Create('TSearchOutboxHandler: no document loader.');
  FName := AName;
  FIndex := AIndex;
  SetLength(FKinds, Length(AKinds));
  for I := 0 to High(AKinds) do
    FKinds[I] := AKinds[I];
  FLoader := ALoader;
end;

function TSearchOutboxHandler.Name: string;
begin
  Result := FName;
end;

function TSearchOutboxHandler.Accepts(const AKind: string): Boolean;
begin
  Result := IndexOfText(FKinds, Length(FKinds), AKind) >= 0;
end;

procedure TSearchOutboxHandler.Handle(const AEvent: TOutboxEvent);
begin
  if Assigned(FIdsReader) then
    Sync(FIdsReader(AEvent))
  else
    Sync(SearchOutboxIds(AEvent.Payload));
end;

procedure TSearchOutboxHandler.Sync(const AIds: array of string);
var
  LIds, LMissing: TArray<string>;
  LFound: array of Boolean;
  LDocs: TSearchDocuments;
  LUpsert, LDelete: ISearchWrite;
  LCount, LMissingCount, I, P: Integer;
begin
  // The ids, checked and each once.
  SetLength(LIds, Length(AIds));
  LCount := 0;
  for I := 0 to High(AIds) do
  begin
    SearchCheckId(AIds[I]);
    if IndexOfText(LIds, LCount, AIds[I]) < 0 then
    begin
      LIds[LCount] := AIds[I];
      Inc(LCount);
    end;
  end;
  if LCount = 0 then
    Exit;
  SetLength(LIds, LCount);

  LDocs := FLoader(LIds);
  SetLength(LFound, LCount);
  for I := 0 to LCount - 1 do
    LFound[I] := False;
  for I := 0 to High(LDocs) do
  begin
    if LDocs[I] = nil then
      raise ESearchArgumentError.CreateFmt('%s: the loader returned nil.', [FName]);
    P := IndexOfText(LIds, LCount, LDocs[I].Id);
    if P < 0 then
      raise ESearchArgumentError.CreateFmt('%s: the loader returned "%s", which wasn''t asked for.',
        [FName, LDocs[I].Id]);
    if LFound[P] then
      raise ESearchArgumentError.CreateFmt('%s: the loader returned "%s" twice.',
        [FName, LDocs[I].Id]);
    LFound[P] := True;
  end;

  SetLength(LMissing, LCount);
  LMissingCount := 0;
  for I := 0 to LCount - 1 do
    if not LFound[I] then
    begin
      LMissing[LMissingCount] := LIds[I];
      Inc(LMissingCount);
    end;
  SetLength(LMissing, LMissingCount);

  // Both writes first, then both waits: on Meilisearch the tasks run meanwhile.
  LUpsert := nil;
  LDelete := nil;
  if Length(LDocs) > 0 then
    LUpsert := FIndex.Upsert(LDocs);
  if LMissingCount > 0 then
    LDelete := FIndex.Delete(LMissing);
  if LUpsert <> nil then
    LUpsert.WaitFor(FWaitTimeoutMs);
  if LDelete <> nil then
    LDelete.WaitFor(FWaitTimeoutMs);
end;

end.
