unit PascalSearch.Mock;

{$I pascalsearch.inc}

{ The contract in memory, for an application's tests without a search engine
  (docs/design.md, S23). Where Meilisearch and Typesense agreed in the engine
  probe the mock does the same; where they differ it does the stricter
  thing, mostly Meilisearch's:

  - schema checks: a filter, sort or facet only on a field declared for it
    (ESearchRequestError, raised by Execute); a filter value of a kind that
    doesn't fit the field (a string for a number...) is also refused, where
    Meilisearch would answer 0 hits and Typesense 400;
  - text: case and accents folded (PcFoldForSearch), words split at anything
    but letters and digits, the last word also a prefix; swAll needs every
    word, swRelaxed takes documents that match the first words, the more
    words the better; NO typo tolerance (a test that needs typos runs on an
    engine); only the schema's Text fields are searched;
  - string equality ignores case but not accents (Meilisearch; Typesense
    also folds accents);
  - NotEq and NoneOf match documents without the field; sort puts documents
    without the field last in both directions;
  - without a sort, matches come in the order documents were first added;
  - a document whose declared field holds the wrong JSON kind is refused on
    its own (WaitFor raises ESearchWriteFailed listing it, the others are
    applied: Typesense's behavior; Meilisearch wouldn't check);
  - Raw parameters and tmEngine raise ESearchNotSupported;
  - an index never ensured raises ESearchIndexNotFound on use.

  Test controls (IMockSearchEngine):
  - DeferWrites: a write is applied only when its WaitFor runs (with every
    write queued before it), like Meilisearch's tasks; a test then catches
    code that searches before waiting. Off: writes are applied at once.
  - FailNextWrite: the next write refuses the ids given (or all of it with
    AWholeBatch, applying none); WaitFor raises ESearchWriteFailed.
  - Unavailable: every call raises ESearchUnavailable, as a server down.

  Thread-safe: one lock for the whole engine. }

interface

uses
  SysUtils,
  SyncObjs,
  PascalJsonMapper.Json,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Errors,
  PascalSearch.Filters,
  PascalSearch.Interfaces;

type
  IMockSearchEngine = interface(ISearchEngine)
    ['{C2E8A4F1-7B3D-4A96-9E15-3D8B6F2A1CCC}']
    function GetDeferWrites: Boolean;
    procedure SetDeferWrites(AValue: Boolean);
    function GetUnavailable: Boolean;
    procedure SetUnavailable(AValue: Boolean);
    /// The next write (Upsert, Delete, DeleteWhere) refuses AIds with
    /// AMessage; with AWholeBatch it applies nothing and lists every id.
    procedure FailNextWrite(const AIds: array of string; const AMessage: string;
      AWholeBatch: Boolean = False);
    /// Writes queued under DeferWrites, not applied yet.
    function PendingWrites: Integer;
    /// Documents in the index (applied writes only); -1 for no such index.
    function DocumentCount(const AIndexName: string): Integer;
    property DeferWrites: Boolean read GetDeferWrites write SetDeferWrites;
    property Unavailable: Boolean read GetUnavailable write SetUnavailable;
  end;

  TMockSearchEngine = class;

  TMockIndexData = class
  private
    FSchema: ISearchSchema;
    FIds: TArray<string>;
    FDocs: TArray<TJsonValue>;   // owned; each an object with its "id"
    function IndexOfId(const AId: string): Integer;
    procedure Put(const AId: string; ADoc: TJsonValue);
    procedure Remove(AIndex: Integer);
  public
    destructor Destroy; override;
  end;

  TMockWriteKind = (mwUpsert, mwDelete, mwDeleteWhere);

  TMockWriteOp = class(TInterfacedObject)
  private
    FKind: TMockWriteKind;
    FIndexName: string;
    FIds: TArray<string>;
    FDocs: TArray<TJsonValue>;   // owned until applied
    FFilter: ISearchFilter;
    FFailIds: TArray<string>;
    FFailMessage: string;
    FFailWhole: Boolean;
    FApplied: Boolean;
    FFailures: TSearchFailures;
  public
    destructor Destroy; override;
  end;

  TMockSearchEngine = class(TInterfacedObject, ISearchEngine, IMockSearchEngine)
  private
    FLock: TCriticalSection;
    FNames: TArray<string>;
    FIndexes: TArray<TMockIndexData>;
    FQueue: TArray<TMockWriteOp>;   // oldest first
    FQueueRefs: TArray<IInterface>; // keeps FQueue's items alive
    FDeferWrites: Boolean;
    FUnavailable: Boolean;
    FFailIds: TArray<string>;
    FFailMessage: string;
    FFailWhole: Boolean;
    FFailArmed: Boolean;
    function FindIndex(const AName: string): TMockIndexData;
    function RequireIndex(const AName: string): TMockIndexData;
    procedure CheckAvailable;
    procedure Submit(AOp: TMockWriteOp);
    procedure Apply(AOp: TMockWriteOp);
    procedure ApplyUpTo(AOp: TMockWriteOp);
    function OpPending(AOp: TMockWriteOp): Boolean;
    procedure RaiseFailures(AOp: TMockWriteOp);
  protected
    // Called by the index handles and the write handles.
    function DoUpsert(const AIndexName: string; const ADocs: array of ISearchDocument): ISearchWrite;
    function DoDelete(const AIndexName: string; const AIds: array of string): ISearchWrite;
    function DoDeleteWhere(const AIndexName: string; const AFilter: ISearchFilter): ISearchWrite;
    function DoGet(const AIndexName, AId: string): ISearchHit;
    function DoGetMany(const AIndexName: string; const AIds: array of string): ISearchHits;
    function DoSearch(const AIndexName: string; const ARequest: TSearchRequest): ISearchResult;
    procedure DoWaitFor(AOp: TMockWriteOp);
    function DoPending(AOp: TMockWriteOp): Boolean;
  public
    class function New: IMockSearchEngine;
    constructor Create;
    destructor Destroy; override;
    { ISearchEngine }
    function EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
    function Index(const AName: string): ISearchIndex;
    function IndexExists(const AName: string): Boolean;
    procedure DropIndex(const AName: string);
    { IMockSearchEngine }
    function GetDeferWrites: Boolean;
    procedure SetDeferWrites(AValue: Boolean);
    function GetUnavailable: Boolean;
    procedure SetUnavailable(AValue: Boolean);
    procedure FailNextWrite(const AIds: array of string; const AMessage: string;
      AWholeBatch: Boolean = False);
    function PendingWrites: Integer;
    function DocumentCount(const AIndexName: string): Integer;
  end;

implementation

uses
  Math,
  PascalCommon.Version,
  PascalCommon.Text,
  PascalSearch.Values,
  PascalSearch.Query;

{$IF PASCALCOMMON_VERSION < 12000}
  {$MESSAGE FATAL 'pascal-search-faa needs pascal-common-faa 1.20.0 or later'}
{$IFEND}

type
  TMockSearchIndex = class(TInterfacedObject, ISearchIndex, ISearchExecutor)
  private
    FEngine: TMockSearchEngine;
    FEngineRef: IMockSearchEngine;   // keeps the engine alive
    FName: string;
  public
    constructor Create(AEngine: TMockSearchEngine; const AName: string);
    function Name: string;
    function Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
    function Delete(const AIds: array of string): ISearchWrite;
    function DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
    function Get(const AId: string): ISearchHit;
    function GetMany(const AIds: array of string): ISearchHits;
    function Search(const AText: string): ISearchQuery;
    function ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
  end;

  TMockSearchWrite = class(TInterfacedObject, ISearchWrite)
  private
    FEngine: TMockSearchEngine;
    FEngineRef: IMockSearchEngine;
    FOp: TMockWriteOp;
    FOpRef: IInterface;
  public
    constructor Create(AEngine: TMockSearchEngine; AOp: TMockWriteOp);
    procedure WaitFor(ATimeoutMs: Integer = 0);
    function Pending: Boolean;
  end;

{ helpers }

function NotFound(const AName: string): ESearchIndexNotFound;
begin
  Result := ESearchIndexNotFound.CreateEngine(Format('Index "%s" not found.', [AName]),
    404, 'index_not_found', '');
end;

function RequestError(const AMessage: string): ESearchRequestError;
begin
  Result := ESearchRequestError.CreateEngine(AMessage, 400, '', '');
end;

function IsWordChar(C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) or (Ord(C) > 127);
end;

// PcFoldForSearch, then runs of letters and digits.
function Tokens(const AText: string): TArray<string>;
var
  S, W: string;
  I: Integer;
begin
  Result := nil;
  S := PcFoldForSearch(AText) + ' ';
  W := '';
  for I := 1 to Length(S) do
    if IsWordChar(S[I]) then
      W := W + S[I]
    else if W <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := W;
      W := '';
    end;
end;

procedure AddTokens(var ATokens: TArray<string>; AValue: TJsonValue);
var
  LNew: TArray<string>;
  I, N: Integer;
begin
  if AValue = nil then
    Exit;
  if AValue.Kind = jkArray then
  begin
    for I := 0 to AValue.Count - 1 do
      AddTokens(ATokens, AValue.Items[I]);
    Exit;
  end;
  if AValue.Kind <> jkString then
    Exit;
  LNew := Tokens(AValue.AsString);
  N := Length(ATokens);
  SetLength(ATokens, N + Length(LNew));
  for I := 0 to High(LNew) do
    ATokens[N + I] := LNew[I];
end;

function JsonKindFits(AKind: TSearchFieldKind; AValue: TJsonValue): Boolean;
var
  I: Integer;
  LInt: Int64;
begin
  if AValue.IsNull then
    Exit(True);
  case AKind of
    skText, skKeyword: Result := AValue.Kind = jkString;
    skKeywords:
      begin
        Result := AValue.Kind = jkArray;
        if Result then
          for I := 0 to AValue.Count - 1 do
            if AValue.Items[I].Kind <> jkString then
              Exit(False);
      end;
    skNumber: Result := AValue.Kind = jkNumber;
    skInteger, skInstant: Result := (AValue.Kind = jkNumber) and AValue.TryAsInt64(LInt);
    skBoolean: Result := AValue.Kind = jkBoolean;
  else
    Result := True;   // skStored: anything
  end;
end;

function ValueFitsField(const AField: TSearchField; const AValue: TSearchValue): Boolean;
begin
  case AField.Kind of
    skText, skKeyword, skKeywords: Result := AValue.Kind = svString;
    skNumber, skInteger, skInstant: Result := AValue.IsNumeric;
    skBoolean: Result := AValue.Kind = svBoolean;
  else
    Result := False;
  end;
end;

procedure CheckFilter(const ASchema: ISearchSchema; const AFilter: ISearchFilter);
var
  I: Integer;
  LField: TSearchField;
begin
  if AFilter.Op in [fopAll, fopAny] then
  begin
    for I := 0 to AFilter.ChildCount - 1 do
      CheckFilter(ASchema, AFilter.Child(I));
    Exit;
  end;
  if AFilter.Field = 'id' then
    Exit;   // strings only, checked when built
  if not ASchema.FindField(AFilter.Field, LField) or not LField.IsFilterable then
    raise RequestError(Format('Field "%s" is not filterable in index "%s".',
      [AFilter.Field, ASchema.Name]));
  for I := 0 to AFilter.ValueCount - 1 do
    if not ValueFitsField(LField, AFilter.Value(I)) then
      raise RequestError(Format('Filter on "%s": the value doesn''t fit a %s field.',
        [AFilter.Field, SearchFieldKindName(LField.Kind)]));
end;

function ScalarEquals(AJson: TJsonValue; const AValue: TSearchValue): Boolean;
var
  A, B: Int64;
begin
  case AJson.Kind of
    jkString:
      Result := (AValue.Kind = svString) and (PcLowerCase(AJson.AsString) = PcLowerCase(AValue.AsString));
    jkNumber:
      if not AValue.IsNumeric then
        Result := False
      else if (AValue.Kind <> svNumber) and AJson.TryAsInt64(A) then
      begin
        B := AValue.AsInteger;
        Result := A = B;
      end
      else
        Result := AJson.AsDouble = AValue.AsNumber;
    jkBoolean:
      Result := (AValue.Kind = svBoolean) and (AJson.AsBoolean = AValue.AsBoolean);
  else
    Result := False;
  end;
end;

function AnyEquals(AJson: TJsonValue; const AFilter: ISearchFilter): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  if AJson.Kind = jkArray then
  begin
    for I := 0 to AJson.Count - 1 do
      if AnyEquals(AJson.Items[I], AFilter) then
        Exit(True);
    Exit;
  end;
  for J := 0 to AFilter.ValueCount - 1 do
    if ScalarEquals(AJson, AFilter.Value(J)) then
      Exit(True);
end;

function Compares(AJson: TJsonValue; const AFilter: ISearchFilter): Boolean;
var
  I: Integer;
  X: Double;
begin
  if AJson.Kind = jkArray then
  begin
    for I := 0 to AJson.Count - 1 do
      if Compares(AJson.Items[I], AFilter) then
        Exit(True);
    Exit(False);
  end;
  if AJson.Kind <> jkNumber then
    Exit(False);
  X := AJson.AsDouble;
  case AFilter.Op of
    fopGt: Result := X > AFilter.Value(0).AsNumber;
    fopGe: Result := X >= AFilter.Value(0).AsNumber;
    fopLt: Result := X < AFilter.Value(0).AsNumber;
    fopLe: Result := X <= AFilter.Value(0).AsNumber;
    fopBetween: Result := (X >= AFilter.Value(0).AsNumber) and (X <= AFilter.Value(1).AsNumber);
  else
    Result := False;
  end;
end;

function Matches(const AFilter: ISearchFilter; ADoc: TJsonValue): Boolean;
var
  I: Integer;
  V: TJsonValue;
begin
  case AFilter.Op of
    fopAll:
      begin
        for I := 0 to AFilter.ChildCount - 1 do
          if not Matches(AFilter.Child(I), ADoc) then
            Exit(False);
        Exit(True);
      end;
    fopAny:
      begin
        for I := 0 to AFilter.ChildCount - 1 do
          if Matches(AFilter.Child(I), ADoc) then
            Exit(True);
        Exit(False);
      end;
  end;
  V := ADoc.Find(AFilter.Field);
  if (V = nil) or V.IsNull then
    Exit(AFilter.Op in [fopNotEq, fopNoneOf]);
  case AFilter.Op of
    fopEq, fopAnyOf: Result := AnyEquals(V, AFilter);
    fopNotEq, fopNoneOf: Result := not AnyEquals(V, AFilter);
  else
    Result := Compares(V, AFilter);
  end;
end;

function FacetText(AValue: TJsonValue): string;
begin
  case AValue.Kind of
    jkString: Result := AValue.AsString;
    jkBoolean:
      if AValue.AsBoolean then Result := 'true' else Result := 'false';
  else
    Result := AValue.ToJson;
  end;
end;

// <0, 0, >0; nil (missing or null) is handled by the caller.
function CompareJson(A, B: TJsonValue): Integer;
begin
  if (A.Kind = jkNumber) and (B.Kind = jkNumber) then
    Result := CompareValue(A.AsDouble, B.AsDouble)
  else if (A.Kind = jkString) and (B.Kind = jkString) then
  begin
    Result := CompareStr(PcFoldForSearch(A.AsString), PcFoldForSearch(B.AsString));
    if Result = 0 then
      Result := CompareStr(A.AsString, B.AsString);
  end
  else if (A.Kind = jkBoolean) and (B.Kind = jkBoolean) then
    Result := Ord(A.AsBoolean) - Ord(B.AsBoolean)
  else
    Result := Ord(A.Kind) - Ord(B.Kind);
end;

function SortValue(ADoc: TJsonValue; const AField: string): TJsonValue;
begin
  Result := ADoc.Find(AField);
  if (Result <> nil) and (Result.IsNull or (Result.Kind in [jkArray, jkObject])) then
    Result := nil;
end;

{ TMockIndexData }

destructor TMockIndexData.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FDocs) do
    FDocs[I].Free;
  inherited Destroy;
end;

function TMockIndexData.IndexOfId(const AId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FIds) do
    if FIds[I] = AId then
      Exit(I);
  Result := -1;
end;

procedure TMockIndexData.Put(const AId: string; ADoc: TJsonValue);
var
  I, N: Integer;
begin
  I := IndexOfId(AId);
  if I >= 0 then
  begin
    FDocs[I].Free;
    FDocs[I] := ADoc;
    Exit;
  end;
  N := Length(FIds);
  SetLength(FIds, N + 1);
  SetLength(FDocs, N + 1);
  FIds[N] := AId;
  FDocs[N] := ADoc;
end;

procedure TMockIndexData.Remove(AIndex: Integer);
var
  I: Integer;
begin
  FDocs[AIndex].Free;
  for I := AIndex to High(FIds) - 1 do
  begin
    FIds[I] := FIds[I + 1];
    FDocs[I] := FDocs[I + 1];
  end;
  SetLength(FIds, Length(FIds) - 1);
  SetLength(FDocs, Length(FDocs) - 1);
end;

{ TMockWriteOp }

destructor TMockWriteOp.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FDocs) do
    FDocs[I].Free;
  inherited Destroy;
end;

{ TMockSearchEngine }

class function TMockSearchEngine.New: IMockSearchEngine;
begin
  Result := TMockSearchEngine.Create;
end;

constructor TMockSearchEngine.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMockSearchEngine.Destroy;
var
  I: Integer;
begin
  FQueue := nil;
  FQueueRefs := nil;
  for I := 0 to High(FIndexes) do
    FIndexes[I].Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMockSearchEngine.CheckAvailable;
begin
  if FUnavailable then
    raise ESearchUnavailable.CreateEngine('The search engine is unavailable (mock).', 0, '', '');
end;

function TMockSearchEngine.FindIndex(const AName: string): TMockIndexData;
var
  I: Integer;
begin
  for I := 0 to High(FNames) do
    if FNames[I] = AName then
      Exit(FIndexes[I]);
  Result := nil;
end;

function TMockSearchEngine.RequireIndex(const AName: string): TMockIndexData;
begin
  Result := FindIndex(AName);
  if Result = nil then
    raise NotFound(AName);
end;

function TMockSearchEngine.EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
var
  LData: TMockIndexData;
  LOld: TSearchField;
  I, N: Integer;
begin
  if ASchema = nil then
    raise ESearchArgumentError.Create('EnsureIndex: the schema is nil.');
  FLock.Enter;
  try
    CheckAvailable;
    LData := FindIndex(ASchema.Name);
    if LData = nil then
    begin
      LData := TMockIndexData.Create;
      N := Length(FNames);
      SetLength(FNames, N + 1);
      SetLength(FIndexes, N + 1);
      FNames[N] := ASchema.Name;
      FIndexes[N] := LData;
    end
    else
      for I := 0 to ASchema.FieldCount - 1 do
        if LData.FSchema.FindField(ASchema.Field(I).Name, LOld)
          and (LOld.Kind <> ASchema.Field(I).Kind) then
          raise ESearchSchemaError.CreateFmt('Index "%s": field "%s" is %s and can''t become %s ' +
            'in place; drop and rebuild the index.', [ASchema.Name, LOld.Name,
            SearchFieldKindName(LOld.Kind), SearchFieldKindName(ASchema.Field(I).Kind)]);
    LData.FSchema := ASchema;
  finally
    FLock.Leave;
  end;
  Result := TMockSearchIndex.Create(Self, ASchema.Name);
end;

function TMockSearchEngine.Index(const AName: string): ISearchIndex;
begin
  SearchCheckIndexName(AName);
  Result := TMockSearchIndex.Create(Self, AName);
end;

function TMockSearchEngine.IndexExists(const AName: string): Boolean;
begin
  FLock.Enter;
  try
    CheckAvailable;
    Result := FindIndex(AName) <> nil;
  finally
    FLock.Leave;
  end;
end;

procedure TMockSearchEngine.DropIndex(const AName: string);
var
  I, J: Integer;
begin
  FLock.Enter;
  try
    CheckAvailable;
    for I := 0 to High(FNames) do
      if FNames[I] = AName then
      begin
        FIndexes[I].Free;
        for J := I to High(FNames) - 1 do
        begin
          FNames[J] := FNames[J + 1];
          FIndexes[J] := FIndexes[J + 1];
        end;
        SetLength(FNames, Length(FNames) - 1);
        SetLength(FIndexes, Length(FIndexes) - 1);
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.GetDeferWrites: Boolean;
begin
  FLock.Enter;
  try
    Result := FDeferWrites;
  finally
    FLock.Leave;
  end;
end;

procedure TMockSearchEngine.SetDeferWrites(AValue: Boolean);
begin
  FLock.Enter;
  try
    FDeferWrites := AValue;
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.GetUnavailable: Boolean;
begin
  FLock.Enter;
  try
    Result := FUnavailable;
  finally
    FLock.Leave;
  end;
end;

procedure TMockSearchEngine.SetUnavailable(AValue: Boolean);
begin
  FLock.Enter;
  try
    FUnavailable := AValue;
  finally
    FLock.Leave;
  end;
end;

procedure TMockSearchEngine.FailNextWrite(const AIds: array of string; const AMessage: string;
  AWholeBatch: Boolean);
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(FFailIds, Length(AIds));
    for I := 0 to High(AIds) do
      FFailIds[I] := AIds[I];
    FFailMessage := AMessage;
    FFailWhole := AWholeBatch;
    FFailArmed := True;
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.PendingWrites: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FQueue);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DocumentCount(const AIndexName: string): Integer;
var
  LData: TMockIndexData;
begin
  FLock.Enter;
  try
    LData := FindIndex(AIndexName);
    if LData = nil then
      Result := -1
    else
      Result := Length(LData.FIds);
  finally
    FLock.Leave;
  end;
end;

// Under the lock. Takes the armed failure, queues or applies the write.
procedure TMockSearchEngine.Submit(AOp: TMockWriteOp);
var
  N: Integer;
begin
  if FFailArmed then
  begin
    AOp.FFailIds := FFailIds;
    AOp.FFailMessage := FFailMessage;
    AOp.FFailWhole := FFailWhole;
    FFailArmed := False;
  end;
  if FDeferWrites then
  begin
    N := Length(FQueue);
    SetLength(FQueue, N + 1);
    SetLength(FQueueRefs, N + 1);
    FQueue[N] := AOp;
    FQueueRefs[N] := AOp;
  end
  else
    Apply(AOp);
end;

// Under the lock.
procedure TMockSearchEngine.Apply(AOp: TMockWriteOp);
var
  LData: TMockIndexData;
  LField: TSearchField;
  LIds: TArray<string>;
  I, J, K: Integer;
  LFailed: Boolean;

  procedure AddFailure(const AId, ACode, AMessage: string);
  var
    N: Integer;
  begin
    N := Length(AOp.FFailures);
    SetLength(AOp.FFailures, N + 1);
    AOp.FFailures[N] := TSearchFailure.Create(AId, ACode, AMessage);
  end;

  function Injected(const AId: string): Boolean;
  var
    X: Integer;
  begin
    for X := 0 to High(AOp.FFailIds) do
      if AOp.FFailIds[X] = AId then
        Exit(True);
    Result := False;
  end;

begin
  AOp.FApplied := True;
  LData := FindIndex(AOp.FIndexName);
  // The ids this write touches, for a whole-batch failure.
  if AOp.FKind = mwUpsert then
  begin
    SetLength(LIds, Length(AOp.FDocs));
    for I := 0 to High(AOp.FDocs) do
      LIds[I] := AOp.FDocs[I].Find('id').AsString;
  end
  else
    LIds := AOp.FIds;
  if (LData = nil) or (AOp.FFailWhole) then
  begin
    AOp.FFailWhole := True;
    for I := 0 to High(LIds) do
      if LData = nil then
        AddFailure(LIds[I], 'index_not_found', Format('Index "%s" not found.', [AOp.FIndexName]))
      else
        AddFailure(LIds[I], 'mock_failure', AOp.FFailMessage);
    if Length(LIds) = 0 then
      AddFailure('', 'mock_failure', AOp.FFailMessage);
    Exit;
  end;
  case AOp.FKind of
    mwUpsert:
      for I := 0 to High(AOp.FDocs) do
      begin
        if Injected(LIds[I]) then
        begin
          AddFailure(LIds[I], 'mock_failure', AOp.FFailMessage);
          Continue;
        end;
        LFailed := False;
        for J := 0 to AOp.FDocs[I].Count - 1 do
          if LData.FSchema.FindField(AOp.FDocs[I].Names[J], LField)
            and not JsonKindFits(LField.Kind, AOp.FDocs[I].Items[J]) then
          begin
            AddFailure(LIds[I], 'invalid_field_value', Format('Field "%s" must hold a %s value.',
              [LField.Name, SearchFieldKindName(LField.Kind)]));
            LFailed := True;
            Break;
          end;
        if LFailed then
          Continue;
        LData.Put(LIds[I], AOp.FDocs[I]);
        AOp.FDocs[I] := nil;
      end;
    mwDelete:
      for I := 0 to High(AOp.FIds) do
        if Injected(AOp.FIds[I]) then
          AddFailure(AOp.FIds[I], 'mock_failure', AOp.FFailMessage)
        else
        begin
          K := LData.IndexOfId(AOp.FIds[I]);
          if K >= 0 then
            LData.Remove(K);
        end;
    mwDeleteWhere:
      for I := High(LData.FIds) downto 0 do
        if Matches(AOp.FFilter, LData.FDocs[I]) then
          LData.Remove(I);
  end;
end;

// Under the lock: applies the queue up to AOp, in order.
procedure TMockSearchEngine.ApplyUpTo(AOp: TMockWriteOp);
var
  LOp: TMockWriteOp;
  I, LCount: Integer;
begin
  if AOp.FApplied then
    Exit;
  LCount := 0;
  for I := 0 to High(FQueue) do
  begin
    LOp := FQueue[I];
    Inc(LCount);
    if not LOp.FApplied then
      Apply(LOp);
    if LOp = AOp then
      Break;
  end;
  FQueue := Copy(FQueue, LCount, MaxInt);
  FQueueRefs := Copy(FQueueRefs, LCount, MaxInt);
end;

function TMockSearchEngine.OpPending(AOp: TMockWriteOp): Boolean;
begin
  Result := not AOp.FApplied;
end;

procedure TMockSearchEngine.RaiseFailures(AOp: TMockWriteOp);
begin
  if Length(AOp.FFailures) = 0 then
    Exit;
  raise ESearchWriteFailed.CreateFailures(AOp.FFailures, AOp.FFailWhole);
end;

procedure TMockSearchEngine.DoWaitFor(AOp: TMockWriteOp);
begin
  FLock.Enter;
  try
    CheckAvailable;
    ApplyUpTo(AOp);
    RaiseFailures(AOp);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoPending(AOp: TMockWriteOp): Boolean;
begin
  FLock.Enter;
  try
    CheckAvailable;
    Result := OpPending(AOp);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoUpsert(const AIndexName: string;
  const ADocs: array of ISearchDocument): ISearchWrite;
var
  LOp: TMockWriteOp;
  I: Integer;
begin
  for I := 0 to High(ADocs) do
    if ADocs[I] = nil then
      raise ESearchArgumentError.CreateFmt('Upsert: document %d is nil.', [I]);
  // The write handle holds the op from here on, also if a check below raises.
  LOp := TMockWriteOp.Create;
  Result := TMockSearchWrite.Create(Self, LOp);
  LOp.FKind := mwUpsert;
  LOp.FIndexName := AIndexName;
  SetLength(LOp.FDocs, Length(ADocs));
  for I := 0 to High(ADocs) do
    LOp.FDocs[I] := ParseJson(ADocs[I].ToJson);
  FLock.Enter;
  try
    CheckAvailable;
    RequireIndex(AIndexName);
    Submit(LOp);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoDelete(const AIndexName: string;
  const AIds: array of string): ISearchWrite;
var
  LOp: TMockWriteOp;
  I: Integer;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  // The write handle holds the op from here on, also if a check below raises.
  LOp := TMockWriteOp.Create;
  Result := TMockSearchWrite.Create(Self, LOp);
  LOp.FKind := mwDelete;
  LOp.FIndexName := AIndexName;
  SetLength(LOp.FIds, Length(AIds));
  for I := 0 to High(AIds) do
    LOp.FIds[I] := AIds[I];
  FLock.Enter;
  try
    CheckAvailable;
    RequireIndex(AIndexName);
    Submit(LOp);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoDeleteWhere(const AIndexName: string;
  const AFilter: ISearchFilter): ISearchWrite;
var
  LOp: TMockWriteOp;
begin
  if AFilter = nil then
    raise ESearchArgumentError.Create('DeleteWhere: the filter is nil.');
  // The write handle holds the op from here on, also if a check below raises.
  LOp := TMockWriteOp.Create;
  Result := TMockSearchWrite.Create(Self, LOp);
  LOp.FKind := mwDeleteWhere;
  LOp.FIndexName := AIndexName;
  LOp.FFilter := AFilter;
  FLock.Enter;
  try
    CheckAvailable;
    CheckFilter(RequireIndex(AIndexName).FSchema, AFilter);
    Submit(LOp);
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoGet(const AIndexName, AId: string): ISearchHit;
var
  LData: TMockIndexData;
  K: Integer;
begin
  SearchCheckId(AId);
  FLock.Enter;
  try
    CheckAvailable;
    LData := RequireIndex(AIndexName);
    K := LData.IndexOfId(AId);
    if K < 0 then
      Result := nil
    else
      Result := TSearchHit.Create(AId, SearchCloneJson(LData.FDocs[K]));
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoGetMany(const AIndexName: string;
  const AIds: array of string): ISearchHits;
var
  LData: TMockIndexData;
  LList: TSearchHitList;
  I, K: Integer;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  LList := TSearchHitList.Create;
  Result := LList;
  FLock.Enter;
  try
    CheckAvailable;
    LData := RequireIndex(AIndexName);
    for I := 0 to High(AIds) do
    begin
      K := LData.IndexOfId(AIds[I]);
      if K >= 0 then
        LList.AddHit(AIds[I], SearchCloneJson(LData.FDocs[K]));
    end;
  finally
    FLock.Leave;
  end;
end;

function TMockSearchEngine.DoSearch(const AIndexName: string;
  const ARequest: TSearchRequest): ISearchResult;
var
  LData: TMockIndexData;
  LSchema: ISearchSchema;
  LField: TSearchField;
  LWords, LDocTokens: TArray<string>;
  LMatch, LLevel, LTmp: TArray<Integer>;
  LResult: TSearchResult;
  LFacet: TSearchFacet;
  LSeen: TArray<string>;
  I, J, K, N, W, LCount, LFrom, LTo, LMaxLevel: Integer;
  LDoc, LProjected, V: TJsonValue;
  LText: string;

  function WordMatches(AWord: Integer): Boolean;
  var
    X: Integer;
  begin
    for X := 0 to High(LDocTokens) do
      if (LDocTokens[X] = LWords[AWord])
        or ((AWord = High(LWords)) and (Copy(LDocTokens[X], 1, Length(LWords[AWord])) = LWords[AWord])) then
        Exit(True);
    Result := False;
  end;

  // Merge sort of LMatch[ALo..AHi] by the request's sorts (stable).
  function Less(A, B: Integer): Boolean;
  var
    S, C: Integer;
    VA, VB: TJsonValue;
  begin
    for S := 0 to High(ARequest.Sorts) do
    begin
      VA := SortValue(LData.FDocs[A], ARequest.Sorts[S].Field);
      VB := SortValue(LData.FDocs[B], ARequest.Sorts[S].Field);
      if (VA = nil) and (VB = nil) then
        Continue;
      if VA = nil then
        Exit(False);   // missing last, both directions
      if VB = nil then
        Exit(True);
      C := CompareJson(VA, VB);
      if ARequest.Sorts[S].Order = soDesc then
        C := -C;
      if C <> 0 then
        Exit(C < 0);
    end;
    Result := False;
  end;

  procedure MergeSort(ALo, AHi: Integer);
  var
    LMid, X, Y, Z: Integer;
  begin
    if ALo >= AHi then
      Exit;
    LMid := (ALo + AHi) div 2;
    MergeSort(ALo, LMid);
    MergeSort(LMid + 1, AHi);
    X := ALo;
    Y := LMid + 1;
    Z := ALo;
    while (X <= LMid) and (Y <= AHi) do
    begin
      if Less(LMatch[Y], LMatch[X]) then
      begin
        LTmp[Z] := LMatch[Y];
        Inc(Y);
      end
      else
      begin
        LTmp[Z] := LMatch[X];
        Inc(X);
      end;
      Inc(Z);
    end;
    while X <= LMid do
    begin
      LTmp[Z] := LMatch[X];
      Inc(X);
      Inc(Z);
    end;
    while Y <= AHi do
    begin
      LTmp[Z] := LMatch[Y];
      Inc(Y);
      Inc(Z);
    end;
    for X := ALo to AHi do
      LMatch[X] := LTmp[X];
  end;

  function Seen(const AValue: string): Boolean;
  var
    X: Integer;
  begin
    for X := 0 to High(LSeen) do
      if LSeen[X] = AValue then
        Exit(True);
    Result := False;
  end;

  procedure CountFacet(const AValue: string);
  var
    X: Integer;
  begin
    if Seen(AValue) then
      Exit;
    SetLength(LSeen, Length(LSeen) + 1);
    LSeen[High(LSeen)] := AValue;
    for X := 0 to High(LFacet.Values) do
      if LFacet.Values[X].Value = AValue then
      begin
        Inc(LFacet.Values[X].Count);
        Exit;
      end;
    SetLength(LFacet.Values, Length(LFacet.Values) + 1);
    LFacet.Values[High(LFacet.Values)].Value := AValue;
    LFacet.Values[High(LFacet.Values)].Count := 1;
  end;

begin
  if Length(ARequest.Raw) > 0 then
    raise ESearchNotSupported.Create('The mock has no engine parameters (Raw).');
  if ARequest.TextMode = tmEngine then
    raise ESearchNotSupported.Create('The mock has no engine text syntax (tmEngine).');
  FLock.Enter;
  try
    CheckAvailable;
    LData := RequireIndex(AIndexName);
    LSchema := LData.FSchema;

    // Checks against the schema.
    if ARequest.Filter <> nil then
      CheckFilter(LSchema, ARequest.Filter);
    for I := 0 to High(ARequest.Sorts) do
      if not LSchema.FindField(ARequest.Sorts[I].Field, LField) or not LField.IsSortable then
        raise RequestError(Format('Field "%s" is not sortable in index "%s".',
          [ARequest.Sorts[I].Field, LSchema.Name]));
    for I := 0 to High(ARequest.Facets) do
      if not LSchema.FindField(ARequest.Facets[I], LField) or not LField.IsFacet then
        raise RequestError(Format('Field "%s" is not a facet in index "%s".',
          [ARequest.Facets[I], LSchema.Name]));
    if (ARequest.PageSize > 0) and (Int64(ARequest.Page - 1) * ARequest.PageSize >= LSchema.MaxHits) then
      raise ESearchArgumentError.CreateFmt('Page %d of %d starts past the index''s MaxHits (%d).',
        [ARequest.Page, ARequest.PageSize, LSchema.MaxHits]);

    // Filter and text.
    LText := ARequest.TextToSend;
    LWords := Tokens(LText);
    SetLength(LMatch, Length(LData.FIds));
    SetLength(LLevel, Length(LData.FIds));
    N := 0;
    LMaxLevel := 0;
    for I := 0 to High(LData.FIds) do
    begin
      LDoc := LData.FDocs[I];
      if (ARequest.Filter <> nil) and not Matches(ARequest.Filter, LDoc) then
        Continue;
      K := Length(LWords);
      if K > 0 then
      begin
        SetLength(LDocTokens, 0);
        for J := 0 to LSchema.FieldCount - 1 do
          if LSchema.Field(J).IsSearchable then
            AddTokens(LDocTokens, LDoc.Find(LSchema.Field(J).Name));
        K := 0;
        for W := 0 to High(LWords) do
          if WordMatches(W) then
            Inc(K)
          else
            Break;
        if (ARequest.Words = swAll) and (K < Length(LWords)) then
          Continue;
        if K = 0 then
          Continue;
      end;
      LMatch[N] := I;
      LLevel[N] := K;
      LMaxLevel := Max(LMaxLevel, K);
      Inc(N);
    end;
    SetLength(LMatch, N);
    SetLength(LLevel, N);

    // Order: the sort, or (swRelaxed) more words first, then insertion.
    SetLength(LTmp, N);
    if Length(ARequest.Sorts) > 0 then
      MergeSort(0, N - 1)
    else if (ARequest.Words = swRelaxed) and (Length(LWords) > 1) then
    begin
      LCount := 0;
      for K := LMaxLevel downto 1 do
        for I := 0 to N - 1 do
          if LLevel[I] = K then
          begin
            LTmp[LCount] := LMatch[I];
            Inc(LCount);
          end;
      for I := 0 to N - 1 do
        LMatch[I] := LTmp[I];
    end;

    LResult := TSearchResult.Create(N, ARequest.Page, ARequest.PageSize);
    Result := LResult;

    // Facets, over every match.
    for I := 0 to High(ARequest.Facets) do
    begin
      LFacet := Default(TSearchFacet);
      LFacet.Field := ARequest.Facets[I];
      for J := 0 to N - 1 do
      begin
        LSeen := nil;
        V := LData.FDocs[LMatch[J]].Find(LFacet.Field);
        if (V = nil) or V.IsNull then
          Continue;
        if V.Kind = jkArray then
        begin
          for K := 0 to V.Count - 1 do
            if not V.Items[K].IsNull then
              CountFacet(FacetText(V.Items[K]));
        end
        else
          CountFacet(FacetText(V));
      end;
      LResult.AddFacet(LFacet);
    end;

    // The page, never past MaxHits.
    if ARequest.PageSize > 0 then
    begin
      LFrom := (ARequest.Page - 1) * ARequest.PageSize;
      LTo := Min(Min(LFrom + ARequest.PageSize, N), LSchema.MaxHits) - 1;
      for I := LFrom to LTo do
      begin
        LDoc := LData.FDocs[LMatch[I]];
        if Length(ARequest.Fields) = 0 then
          LProjected := SearchCloneJson(LDoc)
        else
        begin
          LProjected := TJsonValue.CreateObject;
          LProjected.AddPair('id', TJsonValue.CreateString(LData.FIds[LMatch[I]]));
          for J := 0 to High(ARequest.Fields) do
          begin
            V := LDoc.Find(ARequest.Fields[J]);
            if (V <> nil) and (ARequest.Fields[J] <> 'id') then
              LProjected.AddPair(ARequest.Fields[J], SearchCloneJson(V));
          end;
        end;
        LResult.AddHit(LData.FIds[LMatch[I]], LProjected);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TMockSearchIndex }

constructor TMockSearchIndex.Create(AEngine: TMockSearchEngine; const AName: string);
begin
  inherited Create;
  FEngine := AEngine;
  FEngineRef := AEngine;
  FName := AName;
end;

function TMockSearchIndex.Name: string;
begin
  Result := FName;
end;

function TMockSearchIndex.Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
begin
  Result := FEngine.DoUpsert(FName, ADocs);
end;

function TMockSearchIndex.Delete(const AIds: array of string): ISearchWrite;
begin
  Result := FEngine.DoDelete(FName, AIds);
end;

function TMockSearchIndex.DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
begin
  Result := FEngine.DoDeleteWhere(FName, AFilter);
end;

function TMockSearchIndex.Get(const AId: string): ISearchHit;
begin
  Result := FEngine.DoGet(FName, AId);
end;

function TMockSearchIndex.GetMany(const AIds: array of string): ISearchHits;
begin
  Result := FEngine.DoGetMany(FName, AIds);
end;

function TMockSearchIndex.Search(const AText: string): ISearchQuery;
begin
  Result := TSearchQuery.Create(Self, AText);
end;

function TMockSearchIndex.ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
begin
  Result := FEngine.DoSearch(FName, ARequest);
end;

{ TMockSearchWrite }

constructor TMockSearchWrite.Create(AEngine: TMockSearchEngine; AOp: TMockWriteOp);
begin
  inherited Create;
  FEngine := AEngine;
  FEngineRef := AEngine;
  FOp := AOp;
  FOpRef := AOp;
end;

procedure TMockSearchWrite.WaitFor(ATimeoutMs: Integer);
begin
  FEngine.DoWaitFor(FOp);
end;

function TMockSearchWrite.Pending: Boolean;
begin
  Result := FEngine.DoPending(FOp);
end;

end.
