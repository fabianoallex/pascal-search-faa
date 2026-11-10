unit PascalSearch.IntegrationEnv;

{ Where the integration suite finds the engines, and which one the contract
  suite runs on. Each value comes from an environment variable, with a
  default for the containers tools/engines.sh starts on this machine, so the
  Delphi and FPC Windows runners need no setup; tools/test_integration_docker.sh
  sets them to the Docker network's names.

    SEARCH_CONTRACT_ENGINE      meilisearch (default) or typesense: the engine
                                the contract suite runs on; the runner runs
                                once per engine
    SEARCH_MEILI_URL            http://localhost:17700
    SEARCH_MEILI_KEY            the master key engines.sh gives
    SEARCH_MEILI_TLS_URL        https://localhost:17701 (a name the
                                certificate holds)
    SEARCH_MEILI_TLS_WRONG_URL  https://127.0.0.1:17701 (one it doesn't)
    SEARCH_MEILI_TLS_PLAIN_URL  http://localhost:17701 (http to the TLS port)
    SEARCH_TS_URL, SEARCH_TS_KEY, SEARCH_TS_TLS_URL, SEARCH_TS_TLS_WRONG_URL,
    SEARCH_TS_TLS_PLAIN_URL     the same for Typesense, ports 18108 and 18109
    SEARCH_CA_FILE              the private CA (PEM); default: the first
                                .ci/it-certs/ca.pem above the executable

  Not a test unit: the mirror generator leaves it alone, and both runners
  use this file. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalSearch.Interfaces,
  PascalSearch.Meilisearch,
  PascalSearch.Typesense;

function MeiliUrl: string;
function MeiliKey: string;
function MeiliTlsUrl: string;
function MeiliTlsWrongUrl: string;
function MeiliTlsPlainUrl: string;
function TsUrl: string;
function TsKey: string;
function TsTlsUrl: string;
function TsTlsWrongUrl: string;
function TsTlsPlainUrl: string;
function CaFile: string;

/// The plain-http engines' configurations (key set; Meilisearch waits 30 s).
function MeiliConfig: TMeilisearchConfig;
function TsConfig: TTypesenseConfig;

/// 'meilisearch' or 'typesense' (SEARCH_CONTRACT_ENGINE).
function ContractEngineName: string;

/// A new engine of ContractEngineName: what the contract suite runs on.
function IntegrationContractEngine: ISearchEngine;

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

function TsUrl: string;
begin
  Result := EnvOr('SEARCH_TS_URL', 'http://localhost:18108');
end;

function TsKey: string;
begin
  Result := EnvOr('SEARCH_TS_KEY', 'pascal-search-it-ts-key');
end;

function TsTlsUrl: string;
begin
  Result := EnvOr('SEARCH_TS_TLS_URL', 'https://localhost:18109');
end;

function TsTlsWrongUrl: string;
begin
  Result := EnvOr('SEARCH_TS_TLS_WRONG_URL', 'https://127.0.0.1:18109');
end;

function TsTlsPlainUrl: string;
begin
  Result := EnvOr('SEARCH_TS_TLS_PLAIN_URL', 'http://localhost:18109');
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

function TsConfig: TTypesenseConfig;
begin
  Result := TTypesenseConfig.Create(TsUrl, TsKey);
end;

function ContractEngineName: string;
begin
  Result := LowerCase(EnvOr('SEARCH_CONTRACT_ENGINE', 'meilisearch'));
end;

function IntegrationContractEngine: ISearchEngine;
begin
  if ContractEngineName = 'typesense' then
    Result := TTypesenseEngine.New(TsConfig)
  else if ContractEngineName = 'meilisearch' then
    Result := TMeilisearchEngine.New(MeiliConfig)
  else
    raise Exception.CreateFmt('SEARCH_CONTRACT_ENGINE: "%s" is neither meilisearch nor typesense.',
      [ContractEngineName]);
end;

end.
