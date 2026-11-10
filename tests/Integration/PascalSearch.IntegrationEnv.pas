unit PascalSearch.IntegrationEnv;

{ Where the integration suite finds the engines. Each value comes from an
  environment variable, with a default for the containers tools/engines.sh
  starts on this machine (host ports 17700 and 17701), so the Delphi and FPC
  Windows runners need no setup; tools/test_integration_docker.sh sets them
  to the Docker network's names.

    SEARCH_MEILI_URL            http://localhost:17700
    SEARCH_MEILI_KEY            the master key engines.sh gives
    SEARCH_MEILI_TLS_URL        https://localhost:17701 (a name the
                                certificate holds)
    SEARCH_MEILI_TLS_WRONG_URL  https://127.0.0.1:17701 (one it doesn't)
    SEARCH_MEILI_TLS_PLAIN_URL  http://localhost:17701 (http to the TLS port)
    SEARCH_CA_FILE              the private CA (PEM); default: the first
                                .ci/it-certs/ca.pem above the executable

  Not a test unit: the mirror generator leaves it alone, and both runners
  use this file. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalSearch.Interfaces,
  PascalSearch.Meilisearch;

function MeiliUrl: string;
function MeiliKey: string;
function MeiliTlsUrl: string;
function MeiliTlsWrongUrl: string;
function MeiliTlsPlainUrl: string;
function CaFile: string;

/// The plain-http engine's configuration (key set, waits of 30 s).
function MeiliConfig: TMeilisearchConfig;

/// A new Meilisearch engine: what the contract suite runs on here.
function MeiliContractEngine: ISearchEngine;

implementation

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function MeiliUrl: string;
begin
  Result := EnvOr('SEARCH_MEILI_URL', 'http://localhost:17700');
end;

function MeiliKey: string;
begin
  Result := EnvOr('SEARCH_MEILI_KEY', 'pascal-search-it-master-key-0123');
end;

function MeiliTlsUrl: string;
begin
  Result := EnvOr('SEARCH_MEILI_TLS_URL', 'https://localhost:17701');
end;

function MeiliTlsWrongUrl: string;
begin
  Result := EnvOr('SEARCH_MEILI_TLS_WRONG_URL', 'https://127.0.0.1:17701');
end;

function MeiliTlsPlainUrl: string;
begin
  Result := EnvOr('SEARCH_MEILI_TLS_PLAIN_URL', 'http://localhost:17701');
end;

function CaFile: string;
var
  LDir, LParent, LCandidate: string;
  I: Integer;
begin
  Result := GetEnvironmentVariable('SEARCH_CA_FILE');
  if Result <> '' then
    Exit;
  LDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));
  for I := 1 to 8 do
  begin
    LCandidate := IncludeTrailingPathDelimiter(LDir) + '.ci' + PathDelim + 'it-certs' + PathDelim + 'ca.pem';
    if FileExists(LCandidate) then
      Exit(LCandidate);
    LParent := ExcludeTrailingPathDelimiter(ExtractFilePath(LDir));
    if (LParent = '') or (LParent = LDir) then
      Break;
    LDir := LParent;
  end;
  Result := '';
end;

function MeiliConfig: TMeilisearchConfig;
begin
  Result := TMeilisearchConfig.Create(MeiliUrl, MeiliKey);
  Result.WaitTimeoutMs := 30000;
end;

function MeiliContractEngine: ISearchEngine;
begin
  Result := TMeilisearchEngine.New(MeiliConfig);
end;

end.
