unit PascalSearch.Documents;

{$I pascalsearch.inc}

(* A document to index: a string id and its fields, as JSON
  (docs/design.md, S5).

    Doc := TSearchDocument.New('42')
      .Str('title', 'Café com leite')
      .Strs('tags', ['quente', 'café'])
      .Num('price', 7.5).Int('stock', 3).Bool('available', True)
      .Instant('created_at', LUtc)     // UTC TDateTime, sent as Unix ms
      .Null('category');               // or simply don't set it
    Doc := TSearchDocument.FromObject('42', LProductDto);   // TJsonMapper
    Doc := TSearchDocument.FromJson('{"id":"42","title":"..."}');

  The id is checked at once (SearchCheckId: 1-511 characters of
  [A-Za-z0-9_-], the ground both engines share) and always written as a JSON
  string, first. Setting a field again replaces it, keeping its place. A
  document from JSON or a DTO keeps every member it had (nested objects
  included); its "id" member, when there is one, must be a string or an
  integer, which becomes its decimal text. FromObject maps published
  properties only (pascal-jsonmapper-faa's rule) and ignores the object's
  own "id": the id is the argument.

  An ISearchDocument is not meant to be shared between threads while it is
  still being built. *)

interface

uses
  SysUtils,
  PascalJsonMapper.Json;

type
  ISearchDocument = interface
    ['{8E3A6F51-2B7D-4C19-A0E4-5D9C1B7F3A22}']
    function Id: string;
    function Str(const AName, AValue: string): ISearchDocument;
    function Strs(const AName: string; const AValues: array of string): ISearchDocument;
    function Num(const AName: string; AValue: Double): ISearchDocument;
    function Int(const AName: string; AValue: Int64): ISearchDocument;
    function Bool(const AName: string; AValue: Boolean): ISearchDocument;
    function Instant(const AName: string; AUtc: TDateTime): ISearchDocument;
    function Null(const AName: string): ISearchDocument;
    /// AJson is any JSON value (an object, an array...), parsed now.
    function Json(const AName, AJson: string): ISearchDocument;

    function FieldCount: Integer;
    function FieldName(AIndex: Integer): string;
    /// Owned by the document.
    function FieldValue(AIndex: Integer): TJsonValue;
    /// nil when absent.
    function Find(const AName: string): TJsonValue;
    /// {"id":"...", fields in order}.
    function ToJson: string;
  end;

  TSearchDocuments = TArray<ISearchDocument>;

  TSearchDocument = class(TInterfacedObject, ISearchDocument)
  private
    FId: string;
    FNames: TArray<string>;
    FValues: TArray<TJsonValue>;
    function Put(const AName: string; AValue: TJsonValue): ISearchDocument;
    procedure PutMember(const AName: string; AValue: TJsonValue);
  public
    /// Raises ESearchArgumentError for an invalid id.
    class function New(const AId: string): ISearchDocument;
    /// The published properties of AObject (TJsonMapper), under AId.
    class function FromObject(const AId: string; AObject: TObject): ISearchDocument;
    /// A JSON object with an "id" member (string or integer).
    class function FromJson(const AJson: string): ISearchDocument;
    constructor Create(const AId: string);
    destructor Destroy; override;
    function Id: string;
    function Str(const AName, AValue: string): ISearchDocument;
    function Strs(const AName: string; const AValues: array of string): ISearchDocument;
    function Num(const AName: string; AValue: Double): ISearchDocument;
    function Int(const AName: string; AValue: Int64): ISearchDocument;
    function Bool(const AName: string; AValue: Boolean): ISearchDocument;
    function Instant(const AName: string; AUtc: TDateTime): ISearchDocument;
    function Null(const AName: string): ISearchDocument;
    function Json(const AName, AJson: string): ISearchDocument;
    function FieldCount: Integer;
    function FieldName(AIndex: Integer): string;
    function FieldValue(AIndex: Integer): TJsonValue;
    function Find(const AName: string): TJsonValue;
    function ToJson: string;
  end;

/// A deep copy (through the JSON text).
function SearchCloneJson(AValue: TJsonValue): TJsonValue;

implementation

uses
  PascalJsonMapper.Mapper,
  PascalSearch.Errors,
  PascalSearch.Values;

function SearchCloneJson(AValue: TJsonValue): TJsonValue;
begin
  Result := ParseJson(AValue.ToJson);
end;

{ TSearchDocument }

class function TSearchDocument.New(const AId: string): ISearchDocument;
begin
  Result := TSearchDocument.Create(AId);
end;

constructor TSearchDocument.Create(const AId: string);
begin
  inherited Create;
  SearchCheckId(AId);
  FId := AId;
end;

destructor TSearchDocument.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FValues) do
    FValues[I].Free;
  inherited Destroy;
end;

class function TSearchDocument.FromObject(const AId: string; AObject: TObject): ISearchDocument;
var
  LRoot: TJsonValue;
  LDoc: TSearchDocument;
  I: Integer;
begin
  if AObject = nil then
    raise ESearchArgumentError.Create('TSearchDocument.FromObject: the object is nil.');
  LDoc := TSearchDocument.Create(AId);
  Result := LDoc;
  LRoot := ParseJson(TJsonMapper.Shared.ObjectToJson(AObject));
  try
    for I := 0 to LRoot.Count - 1 do
      if LRoot.Names[I] <> 'id' then
        LDoc.PutMember(LRoot.Names[I], SearchCloneJson(LRoot.Items[I]));
  finally
    LRoot.Free;
  end;
end;

class function TSearchDocument.FromJson(const AJson: string): ISearchDocument;
var
  LRoot, LId: TJsonValue;
  LDoc: TSearchDocument;
  LIdText: string;
  LInt: Int64;
  I: Integer;
begin
  try
    LRoot := ParseJson(AJson);
  except
    on E: EJsonError do
      raise ESearchArgumentError.Create('TSearchDocument.FromJson: ' + E.Message);
  end;
  try
    if LRoot.Kind <> jkObject then
      raise ESearchArgumentError.Create('TSearchDocument.FromJson: the JSON is not an object.');
    LId := LRoot.Find('id');
    if LId = nil then
      raise ESearchArgumentError.Create('TSearchDocument.FromJson: the object has no "id".');
    case LId.Kind of
      jkString: LIdText := LId.AsString;
      jkNumber:
        if LId.TryAsInt64(LInt) then
          LIdText := IntToStr(LInt)
        else
          raise ESearchArgumentError.Create('TSearchDocument.FromJson: "id" is not an integer.');
    else
      raise ESearchArgumentError.Create('TSearchDocument.FromJson: "id" must be a string or an integer.');
    end;
    LDoc := TSearchDocument.Create(LIdText);
    Result := LDoc;
    for I := 0 to LRoot.Count - 1 do
      if LRoot.Names[I] <> 'id' then
        LDoc.PutMember(LRoot.Names[I], SearchCloneJson(LRoot.Items[I]));
  finally
    LRoot.Free;
  end;
end;

// No name check: a member read from JSON or a DTO is kept as it is (the
// engine decides what it accepts). The builder methods check through Put.
procedure TSearchDocument.PutMember(const AName: string; AValue: TJsonValue);
var
  I, N: Integer;
begin
  for I := 0 to High(FNames) do
    if FNames[I] = AName then
    begin
      FValues[I].Free;
      FValues[I] := AValue;
      Exit;
    end;
  N := Length(FNames);
  SetLength(FNames, N + 1);
  SetLength(FValues, N + 1);
  FNames[N] := AName;
  FValues[N] := AValue;
end;

function TSearchDocument.Put(const AName: string; AValue: TJsonValue): ISearchDocument;
begin
  Result := Self;
  try
    SearchCheckFieldName(AName);
  except
    AValue.Free;
    raise;
  end;
  PutMember(AName, AValue);
end;

function TSearchDocument.Id: string;
begin
  Result := FId;
end;

function TSearchDocument.Str(const AName, AValue: string): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateString(AValue));
end;

function TSearchDocument.Strs(const AName: string; const AValues: array of string): ISearchDocument;
var
  LArray: TJsonValue;
  I: Integer;
begin
  LArray := TJsonValue.CreateArray;
  for I := 0 to High(AValues) do
    LArray.Add(TJsonValue.CreateString(AValues[I]));
  Result := Put(AName, LArray);
end;

function TSearchDocument.Num(const AName: string; AValue: Double): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateNumberText(SearchNumberText(AValue)));
end;

function TSearchDocument.Int(const AName: string; AValue: Int64): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateInt64(AValue));
end;

function TSearchDocument.Bool(const AName: string; AValue: Boolean): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateBoolean(AValue));
end;

function TSearchDocument.Instant(const AName: string; AUtc: TDateTime): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateInt64(SearchInstantToMs(AUtc)));
end;

function TSearchDocument.Null(const AName: string): ISearchDocument;
begin
  Result := Put(AName, TJsonValue.CreateNull);
end;

function TSearchDocument.Json(const AName, AJson: string): ISearchDocument;
var
  LValue: TJsonValue;
begin
  try
    LValue := ParseJson(AJson);
  except
    on E: EJsonError do
      raise ESearchArgumentError.CreateFmt('Field "%s": %s', [AName, E.Message]);
  end;
  Result := Put(AName, LValue);
end;

function TSearchDocument.FieldCount: Integer;
begin
  Result := Length(FNames);
end;

function TSearchDocument.FieldName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

function TSearchDocument.FieldValue(AIndex: Integer): TJsonValue;
begin
  Result := FValues[AIndex];
end;

function TSearchDocument.Find(const AName: string): TJsonValue;
var
  I: Integer;
begin
  for I := 0 to High(FNames) do
    if FNames[I] = AName then
      Exit(FValues[I]);
  Result := nil;
end;

function TSearchDocument.ToJson: string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('id');
    W.WriteString(FId);
    for I := 0 to High(FNames) do
    begin
      W.Name(FNames[I]);
      W.WriteValue(FValues[I]);
    end;
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

end.
