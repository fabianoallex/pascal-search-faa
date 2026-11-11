unit PascalSearch.EngineJson;

{$I pascalsearch.inc}

{ What the engine adapters share to read and write the engines' JSON: no
  HTTP here (the core doesn't depend on pascal-common-faa's client), only
  pascal-jsonmapper-faa's DOM and the library's errors.

  An answer that isn't the JSON the adapter expects is ESearchUnavailable:
  the request reached something, but not an engine that answered as one
  (a proxy's HTML page, a truncated body). }

interface

uses
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Schema;

/// ABody parsed; ESearchUnavailable naming AWhat ('Typesense GET /x') when
/// it isn't JSON. The caller owns the result.
function SearchParseAnswer(const ABody, AWhat: string): TJsonValue;

/// The member AName of the object AJson as text: a string as is, a number
/// as written, true/false; '' when AJson isn't an object, or the member is
/// absent, null or a container.
function SearchJsonText(AJson: TJsonValue; const AName: string): string;

/// The member AName of the object AJson; nil when AJson isn't an object or
/// has no such member.
function SearchJsonMember(AJson: TJsonValue; const AName: string): TJsonValue;

/// A copy of the object AJson without its members named AName.
function SearchCloneJsonWithout(AJson: TJsonValue; const AName: string): TJsonValue;

/// A document id as an engine returns it: a string, or the text of a number
/// (a document written by something other than this library); '' otherwise.
function SearchJsonId(AValue: TJsonValue): string;

/// Writes "AName": [AValues...] as strings.
procedure SearchWriteStrings(W: TJsonWriter; const AName: string; const AValues: array of string);

/// The kind named by SearchFieldKindName ('text', 'keyword'...); False for
/// any other text.
function SearchFieldKindByName(const AName: string; out AKind: TSearchFieldKind): Boolean;

implementation

uses
  PascalSearch.Errors,
  PascalSearch.Documents;

function SearchParseAnswer(const ABody, AWhat: string): TJsonValue;
begin
  try
    Result := ParseJson(ABody);
  except
    on E: EJsonError do
      raise ESearchUnavailable.CreateEngine(Format('%s: the answer isn''t JSON (%s).',
        [AWhat, E.Message]), 0, '', '');
  end;
end;

function SearchCloneJsonWithout(AJson: TJsonValue; const AName: string): TJsonValue;
var
  I: Integer;
begin
  if AJson.Kind <> jkObject then
    Exit(SearchCloneJson(AJson));
  Result := TJsonValue.CreateObject;
  try
    for I := 0 to AJson.Count - 1 do
      if AJson.Names[I] <> AName then
        Result.AddPair(AJson.Names[I], SearchCloneJson(AJson.Items[I]));
  except
    Result.Free;
    raise;
  end;
end;

function SearchJsonMember(AJson: TJsonValue; const AName: string): TJsonValue;
begin
  if (AJson = nil) or (AJson.Kind <> jkObject) then
    Result := nil
  else
    Result := AJson.Find(AName);
end;

function SearchJsonText(AJson: TJsonValue; const AName: string): string;
var
  V: TJsonValue;
begin
  Result := '';
  V := SearchJsonMember(AJson, AName);
  if V = nil then
    Exit;
  case V.Kind of
    jkString: Result := V.AsString;
    jkNumber: Result := V.NumberText;
    jkBoolean:
      if V.AsBoolean then Result := 'true' else Result := 'false';
  end;
end;

function SearchJsonId(AValue: TJsonValue): string;
begin
  if AValue = nil then
    Result := ''
  else if AValue.Kind = jkString then
    Result := AValue.AsString
  else if AValue.Kind = jkNumber then
    Result := AValue.NumberText
  else
    Result := '';
end;

procedure SearchWriteStrings(W: TJsonWriter; const AName: string; const AValues: array of string);
var
  I: Integer;
begin
  W.Name(AName);
  W.BeginArray;
  for I := 0 to High(AValues) do
    W.WriteString(AValues[I]);
  W.EndArray;
end;

function SearchFieldKindByName(const AName: string; out AKind: TSearchFieldKind): Boolean;
var
  K: TSearchFieldKind;
begin
  for K := Low(TSearchFieldKind) to High(TSearchFieldKind) do
    if SearchFieldKindName(K) = AName then
    begin
      AKind := K;
      Exit(True);
    end;
  AKind := skStored;
  Result := False;
end;

end.
