unit PascalSearch.Errors;

{$I pascalsearch.inc}

{ The library's exceptions, and the checks that raise ESearchArgumentError at
  the call instead of letting an engine refuse later (docs/design.md, S4, S5,
  S13, S21).

  The classes are chosen by what the caller does next:
  - ESearchUnavailable: no answer, or a 5xx; try again later.
  - ESearchAuthError: a wrong or missing key; fix the configuration.
  - ESearchIndexNotFound: the index doesn't exist; EnsureIndex it.
  - ESearchRequestError: the engine refused the request (an undeclared
    filter field, a bad value); a bug in the caller.
  - ESearchWriteFailed: WaitFor found refused documents (Failures).
  - ESearchTimeout: WaitFor's limit passed with the write still pending.
  - ESearchSchemaError: EnsureIndex can't change the index in place.
  - ESearchArgumentError: refused before anything was sent.
  - ESearchNotSupported: an engine-specific feature on the mock (Raw, the
    engine's text syntax), or one an adapter doesn't have.
  Every one carries HttpStatus, EngineCode and EngineMessage (0 and empty
  when the error didn't come from an engine).

  The checks hold the common ground of Meilisearch and Typesense measured by
  the engine probe:
  - an id: 1-511 characters of [A-Za-z0-9_-] (Meilisearch's rule; Typesense
    accepts more);
  - an index name: 1-64 characters of [A-Za-z0-9_-];
  - a field name: [A-Za-z_][A-Za-z0-9_]*, at most 64 characters; it is
    written unquoted in both engines' filters, so nothing else may get in.
    "id" is the document's id, never a declared field. }

interface

uses
  SysUtils;

type
  ESearchError = class(Exception)
  private
    FHttpStatus: Integer;
    FEngineCode: string;
    FEngineMessage: string;
  public
    /// An error the engine answered: AMessage for people, the rest as received.
    constructor CreateEngine(const AMessage: string; AHttpStatus: Integer;
      const AEngineCode, AEngineMessage: string);
    property HttpStatus: Integer read FHttpStatus;
    property EngineCode: string read FEngineCode;
    property EngineMessage: string read FEngineMessage;
  end;

  ESearchUnavailable = class(ESearchError);
  ESearchAuthError = class(ESearchError);
  ESearchIndexNotFound = class(ESearchError);
  ESearchRequestError = class(ESearchError);
  ESearchTimeout = class(ESearchError);
  ESearchSchemaError = class(ESearchError);
  ESearchArgumentError = class(ESearchError);
  ESearchNotSupported = class(ESearchError);

  /// One document an engine refused.
  TSearchFailure = record
    Id: string;
    Code: string;
    Message: string;
    class function Create(const AId, ACode, AMessage: string): TSearchFailure; static;
  end;

  TSearchFailures = TArray<TSearchFailure>;

  ESearchWriteFailed = class(ESearchError)
  private
    FFailures: TSearchFailures;
    FWholeBatch: Boolean;
  public
    /// AWholeBatch: the engine applied none of the write's documents
    /// (Meilisearch's tasks are all or nothing); AFailures then lists every
    /// id of the write. Otherwise only the listed ones were refused.
    constructor CreateFailures(const AFailures: TSearchFailures; AWholeBatch: Boolean);
    property Failures: TSearchFailures read FFailures;
    property WholeBatch: Boolean read FWholeBatch;
  end;

const
  SEARCH_MAX_ID_LENGTH = 511;
  SEARCH_MAX_NAME_LENGTH = 64;

/// True when AId is 1-511 characters of [A-Za-z0-9_-].
function SearchIsValidId(const AId: string): Boolean;
/// True when AName is 1-64 characters of [A-Za-z0-9_-].
function SearchIsValidIndexName(const AName: string): Boolean;
/// True when AName is [A-Za-z_][A-Za-z0-9_]*, at most 64 characters.
function SearchIsValidFieldName(const AName: string): Boolean;

/// Raise ESearchArgumentError naming the value when it isn't valid.
procedure SearchCheckId(const AId: string);
procedure SearchCheckIndexName(const AName: string);
/// Also refuses "id": the document's id is not a field.
procedure SearchCheckFieldName(const AName: string);

implementation

{ ESearchError }

constructor ESearchError.CreateEngine(const AMessage: string; AHttpStatus: Integer;
  const AEngineCode, AEngineMessage: string);
begin
  inherited Create(AMessage);
  FHttpStatus := AHttpStatus;
  FEngineCode := AEngineCode;
  FEngineMessage := AEngineMessage;
end;

{ TSearchFailure }

class function TSearchFailure.Create(const AId, ACode, AMessage: string): TSearchFailure;
begin
  Result.Id := AId;
  Result.Code := ACode;
  Result.Message := AMessage;
end;

{ ESearchWriteFailed }

constructor ESearchWriteFailed.CreateFailures(const AFailures: TSearchFailures;
  AWholeBatch: Boolean);
var
  LText: string;
begin
  if Length(AFailures) = 0 then
    LText := 'The search engine refused the write.'
  else if AWholeBatch then
    LText := Format('The search engine refused the whole write (%d documents); first: %s: %s',
      [Length(AFailures), AFailures[0].Id, AFailures[0].Message])
  else
    LText := Format('The search engine refused %d document(s); first: %s: %s',
      [Length(AFailures), AFailures[0].Id, AFailures[0].Message]);
  inherited Create(LText);
  FFailures := Copy(AFailures, 0, Length(AFailures));
  FWholeBatch := AWholeBatch;
end;

{ checks }

function IsAsciiLetter(C: Char): Boolean;
begin
  Result := ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z'));
end;

function IsAsciiDigit(C: Char): Boolean;
begin
  Result := (C >= '0') and (C <= '9');
end;

function IsIdChars(const S: string; AMaxLength: Integer): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and (Length(S) <= AMaxLength);
  if not Result then
    Exit;
  for I := 1 to Length(S) do
    if not (IsAsciiLetter(S[I]) or IsAsciiDigit(S[I]) or (S[I] = '_') or (S[I] = '-')) then
      Exit(False);
end;

function SearchIsValidId(const AId: string): Boolean;
begin
  Result := IsIdChars(AId, SEARCH_MAX_ID_LENGTH);
end;

function SearchIsValidIndexName(const AName: string): Boolean;
begin
  Result := IsIdChars(AName, SEARCH_MAX_NAME_LENGTH);
end;

function SearchIsValidFieldName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := (AName <> '') and (Length(AName) <= SEARCH_MAX_NAME_LENGTH)
    and (IsAsciiLetter(AName[1]) or (AName[1] = '_'));
  if not Result then
    Exit;
  for I := 2 to Length(AName) do
    if not (IsAsciiLetter(AName[I]) or IsAsciiDigit(AName[I]) or (AName[I] = '_')) then
      Exit(False);
end;

// Only what is safe to repeat in a message: the value is cut, and its
// characters outside printable ASCII shown as '?'.
function Shown(const S: string): string;
var
  I: Integer;
begin
  Result := Copy(S, 1, 80);
  for I := 1 to Length(Result) do
    if (Result[I] < ' ') or (Result[I] > '~') then
      Result[I] := '?';
  if Length(S) > 80 then
    Result := Result + '...';
end;

procedure SearchCheckId(const AId: string);
begin
  if not SearchIsValidId(AId) then
    raise ESearchArgumentError.CreateFmt('Invalid document id "%s": 1 to %d characters of ' +
      'A-Z, a-z, 0-9, "_" and "-".', [Shown(AId), SEARCH_MAX_ID_LENGTH]);
end;

procedure SearchCheckIndexName(const AName: string);
begin
  if not SearchIsValidIndexName(AName) then
    raise ESearchArgumentError.CreateFmt('Invalid index name "%s": 1 to %d characters of ' +
      'A-Z, a-z, 0-9, "_" and "-".', [Shown(AName), SEARCH_MAX_NAME_LENGTH]);
end;

procedure SearchCheckFieldName(const AName: string);
begin
  if not SearchIsValidFieldName(AName) then
    raise ESearchArgumentError.CreateFmt('Invalid field name "%s": a letter or "_", then ' +
      'letters, digits or "_", at most %d characters.', [Shown(AName), SEARCH_MAX_NAME_LENGTH]);
  if AName = 'id' then
    raise ESearchArgumentError.Create('"id" is the document''s id, not a field.');
end;

end.
