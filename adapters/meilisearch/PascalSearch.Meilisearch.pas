unit PascalSearch.Meilisearch;

{$I pascalsearch.inc}

(* The contract on Meilisearch (pinned and probed: v1.56.2), over
  pascal-common-faa's HTTP client (PascalCommon.Http, 1.33.0 or later), which
  verifies TLS on both compilers.

    Config := TMeilisearchConfig.Create('https://search.local:7700', LKey);
    Config.Http.Tls.CaFile := 'ca.pem';      // a private CA; zeroed: the system store
    Engine := TMeilisearchEngine.New(Config);

  Keep one engine per server and share it between threads: it owns one HTTP
  transport, whose pool of kept-alive connections serves the task polling.

  Telemetry (design, section 13): the transport, the engine's own or the one
  given to New, is wrapped with PcNewTracedHttpTransport. Each request is a
  client span under the thread's current span (none without one) carrying
  its traceparent, and a point of http.client.request.duration on PcMetrics.
  Don't pass a transport that is already wrapped: each call would make two
  spans and two points. url.full has the path (index names, a document's id
  in Get), never the query; the key goes in a header. The polls of a wait
  make no span, only the metric: under a current span the wait is one
  internal span, meilisearch.wait_task, with meilisearch.task.uid,
  .status and .polls, an error when the task didn't succeed.

  How the contract maps (docs/design.md; "finding N" is
  docs/engine-findings.md):
  - EnsureIndex creates the index with primary key "id" and sends the
    settings: searchableAttributes (the Text fields, in order),
    filterableAttributes (filter and facet fields, and "id"),
    sortableAttributes, pagination.maxTotalHits (the schema's MaxHits) and
    facet values sorted by count. It waits for those tasks: a filter right
    after a settings call fails until its task ends (finding 3). An index
    with another primary key raises ESearchSchemaError. Meilisearch has no
    field kinds, so a kind change applies in place.
  - Writes are tasks (finding 1). Upsert is POST /documents (replaces whole
    documents), Delete is delete-batch, DeleteWhere is delete by filter.
    Each first checks that the index exists (GET /indexes/{uid}): Meilisearch
    would otherwise create it on the first write, without the schema
    (finding 8). That check and the write are two requests: an index dropped
    between them is still created.
  - WaitFor polls GET /tasks/{uid}, from 5 ms doubling up to 200 ms, through
    TSleep and TTicker (PascalCommon.SystemContext), so unit tests don't
    sleep. A task is all or nothing (finding 2): a failed write raises
    ESearchWriteFailed listing every id with WholeBatch = True.
  - A write is a POST, and the transport never sends a POST twice. A write
    whose request got no answer raises ESearchUnavailable: Meilisearch may or
    may not have queued it. Upsert and Delete are idempotent, so the caller
    sends them again.
  - Search uses page/hitsPerPage, which give an exact total (finding 33), and
    matchingStrategy "all" or "last" (swAll, swRelaxed). A page that starts
    past MaxHits raises ESearchArgumentError; for an index this engine
    didn't ensure, MaxHits is read from the index's settings and kept
    CacheMs (60 s by default), so another process's ReplaceIndex is seen.
  - Highlight: attributesToHighlight with #1/#2 as the tags (findings 62,
    71), read from _formatted, which is taken out of the hit's document.
    Meilisearch highlights any attribute: the Text-field check is the
    mock's and Typesense's only.
  - ReplaceIndex swaps the target with the source (/swap-indexes, atomic,
    finding 57) and drops the source, which then holds the old documents;
    a missing target is renamed into ("rename": true, finding 58).
  - ListIds pages POST /documents/fetch (fields ["id"], 1000 a page), which
    isn't capped by maxTotalHits (finding 61).
  - SetSynonyms writes the synonyms setting: each word of an equivalent
    group a key to the others, a one-way root a key to its words.
  - Filters are written by MeilisearchFilterText: every string in double
    quotes, with backslash and quote escaped (finding 21).
  - Errors: 401/403 ESearchAuthError, index_not_found ESearchIndexNotFound,
    5xx and no answer ESearchUnavailable, any other 4xx ESearchRequestError,
    with Meilisearch's code and message in EngineCode and EngineMessage.

  Native access (S20, S29): IMeilisearchEngine.Send for any endpoint, with
  the key and the error mapping applied, WaitForTask for the tasks it
  starts, and SetTypoTolerance, SetRankingRules and SetStopWords, each
  waiting for its task. Like the synonyms, these settings belong to the
  index: set them on a rebuilt index before ReplaceIndex. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalCommon.Http,
  PascalCommon.Http.Client,
  PascalSearch.Schema,
  PascalSearch.Filters,
  PascalSearch.Interfaces;

const
  /// TMeilisearchConfig.WaitTimeoutMs = 0.
  MEILISEARCH_DEFAULT_WAIT_MS = 30000;
  /// TMeilisearchConfig.CacheMs = 0.
  MEILISEARCH_DEFAULT_CACHE_MS = 60000;
  /// The internal span around a wait for a task, under the current span.
  MEILISEARCH_WAIT_SPAN = 'meilisearch.wait_task';

type
  TMeilisearchConfig = record
    /// The server, http or https, without a path ('http://localhost:7700').
    Url: string;
    /// Sent as "Authorization: Bearer ..."; '' sends no key.
    ApiKey: string;
    /// Each request's deadline per wait (connect, read, write).
    /// 0 = the transport's default, 15 s.
    TimeoutMs: Integer;
    /// What WaitFor(0) and the engine's own waits allow a task.
    /// 0 = MEILISEARCH_DEFAULT_WAIT_MS.
    WaitTimeoutMs: Integer;
    /// How long an index's MaxHits read from the server is kept.
    /// 0 = MEILISEARCH_DEFAULT_CACHE_MS.
    CacheMs: Integer;
    /// The HTTP transport: Http.Tls.CaFile for a private CA (PEM), CertFile/
    /// KeyFile/CertPassword for a client certificate, the pool's limits.
    /// Zeroed: https verified against the system store and the host name.
    /// Http.Tls.SkipServerVerification is INSECURE: for a lab only.
    Http: TPcHttpOptions;
    class function Create(const AUrl: string; const AApiKey: string = ''): TMeilisearchConfig; static;
  end;

  /// The typoTolerance setting (finding 69).
  TMeilisearchTypoTolerance = record
    Enabled: Boolean;
    /// The shortest word that accepts one typo, and two.
    OneTypo: Integer;
    TwoTypos: Integer;
    /// Words and attributes searched without typos.
    DisableOnWords: TArray<string>;
    DisableOnAttributes: TArray<string>;
    /// Meilisearch's own: enabled, 5 and 9, nothing disabled.
    class function Standard: TMeilisearchTypoTolerance; static;
  end;

  IMeilisearchEngine = interface(ISearchEngine)
    ['{6A1F3C82-9D4E-4B57-A3C6-2E8F7B1D5C90}']
    function Config: TMeilisearchConfig;
    /// One request to APath ('/indexes/x/settings/synonyms'), with the key;
    /// returns the body of a 2xx answer, raises as the contract does for
    /// anything else. APath goes as written: encode its parts.
    function Send(const AMethod, APath: string; const ABody: string = ''): string;
    /// Waits for a task (the taskUid of a Send's answer). Raises
    /// ESearchTimeout, or the task's error mapped as an answer's would be.
    procedure WaitForTask(ATaskUid: Int64; ATimeoutMs: Integer = 0);
    /// The index's typoTolerance setting; returns once applied.
    procedure SetTypoTolerance(const AIndexName: string; const AValue: TMeilisearchTypoTolerance);
    /// The index's rankingRules ('words', 'typo', 'proximity', 'attribute',
    /// 'sort', 'exactness', 'price:asc'...); returns once applied.
    procedure SetRankingRules(const AIndexName: string; const ARules: array of string);
    /// The index's stopWords; returns once applied.
    procedure SetStopWords(const AIndexName: string; const AWords: array of string);
  end;

  /// A task as GET /tasks/{uid} reports it.
  TMeilisearchTask = record
    Uid: Int64;
    /// enqueued, processing, succeeded, failed or canceled.
    Status: string;
    ErrorCode: string;
    ErrorType: string;
    ErrorMessage: string;
    function Finished: Boolean;
  end;

  TMeilisearchEngine = class(TInterfacedObject, ISearchEngine, IMeilisearchEngine)
  private
    FConfig: TMeilisearchConfig;
    FBase: string;
    FTransport: IPcHttpTransport;
    /// The same inner transport (and pool), recorded without spans: the
    /// task polls of a wait.
    FPollTransport: IPcHttpTransport;
    FLock: TCriticalSection;
    FMaxHitsNames: TArray<string>;
    FMaxHitsValues: TArray<Integer>;
    FMaxHitsAt: TArray<UInt64>;
    function WaitLimit(ATimeoutMs: Integer): Integer;
    function Exchange(const AMethod, APath, ABody: string): TPcHttpResponse; overload;
    function Exchange(const ATransport: IPcHttpTransport;
      const AMethod, APath, ABody: string): TPcHttpResponse; overload;
    procedure RaiseAnswer(const AMethod, APath: string; const AResponse: TPcHttpResponse);
    function Call(const AMethod, APath, ABody: string): string; overload;
    function Call(const ATransport: IPcHttpTransport; const AMethod, APath, ABody: string): string; overload;
    function StartTask(const AMethod, APath, ABody: string): Int64;
    /// APoll: a read inside a wait, recorded without a span.
    function ReadTask(ATaskUid: Int64; APoll: Boolean = False): TMeilisearchTask;
    function PollTask(ATaskUid: Int64; ALimit: Integer; out APolls: Integer): TMeilisearchTask;
    function AwaitTask(ATaskUid: Int64; ATimeoutMs: Integer): TMeilisearchTask;
    procedure RaiseTask(const ATask: TMeilisearchTask; const AWhat: string);
    function FindIndexInfo(const AName: string; out APrimaryKey: string): Boolean;
    procedure RequireIndex(const AName: string);
    function CachedMaxHits(const AName: string; out AValue: Integer): Boolean;
    procedure CacheMaxHits(const AName: string; AValue: Integer);
    procedure ForgetMaxHits(const AName: string);
    function MaxHitsOf(const AName: string): Integer;
    procedure PutSetting(const AIndexName, ASetting, AMethod, ABody: string);
  public
    /// Raises ESearchArgumentError for a URL that isn't http(s) or has a path.
    class function New(const AConfig: TMeilisearchConfig): IMeilisearchEngine; overload;
    /// With a transport of the caller's (tests: TPcFakeHttpTransport);
    /// AConfig.Http is then unused.
    class function New(const AConfig: TMeilisearchConfig;
      const ATransport: IPcHttpTransport): IMeilisearchEngine; overload;
    constructor Create(const AConfig: TMeilisearchConfig; const ATransport: IPcHttpTransport);
    destructor Destroy; override;
    function Config: TMeilisearchConfig;
    function Send(const AMethod, APath: string; const ABody: string = ''): string;
    procedure WaitForTask(ATaskUid: Int64; ATimeoutMs: Integer = 0);
    function EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
    function Index(const AName: string): ISearchIndex;
    function IndexExists(const AName: string): Boolean;
    procedure DropIndex(const AName: string);
    procedure ReplaceIndex(const ATarget, ASource: string);
    procedure SetTypoTolerance(const AIndexName: string; const AValue: TMeilisearchTypoTolerance);
    procedure SetRankingRules(const AIndexName: string; const ARules: array of string);
    procedure SetStopWords(const AIndexName: string; const AWords: array of string);
  end;

/// The synonyms setting for AGroups: each word of an equivalent group a key
/// to the others, a one-way root a key to its words; a key in several
/// groups gets all their words, once each.
function MeilisearchSynonymsJson(const AGroups: array of TSearchSynonym): string;

/// AFilter in Meilisearch's syntax: strings in double quotes with '\' and
/// '"' escaped, numbers in plain decimal, instants as Unix milliseconds,
/// groups in parentheses. AnyOf/NoneOf are IN/NOT IN lists, Between is TO.
function MeilisearchFilterText(const AFilter: ISearchFilter): string;

/// AValue in double quotes, '\' and '"' escaped with a backslash.
function MeilisearchQuote(const AValue: string): string;

implementation

uses
  PascalCommon.Version,
  PascalCommon.Utf8,
  PascalCommon.SystemContext,
  PascalCommon.Tracing,
  PascalCommon.Http.Telemetry,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Documents,
  PascalSearch.Query,
  PascalSearch.EngineJson;

{$IF PASCALCOMMON_VERSION < 13300}
  {$MESSAGE FATAL 'pascal-search-faa needs pascal-common-faa 1.33.0 or later (PascalCommon.Http.Telemetry)'}
{$IFEND}

const
  ENGINE_NAME = 'Meilisearch';
  POLL_FIRST_MS = 5;
  POLL_MAX_MS = 200;
  /// Ids per page of ListIds.
  LIST_PAGE = 1000;

type
  TMeilisearchIndex = class(TInterfacedObject, ISearchIndex, ISearchExecutor)
  private
    FEngineRef: IMeilisearchEngine;
    FEngine: TMeilisearchEngine;
    FName: string;
    FPath: string;
    function NewWrite(ATaskUid: Int64; const AIds: TArray<string>; AByFilter: Boolean): ISearchWrite;
  public
    constructor Create(AEngine: TMeilisearchEngine; const AName: string);
    function Name: string;
    function Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
    function Delete(const AIds: array of string): ISearchWrite;
    function DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
    function Get(const AId: string): ISearchHit;
    function GetMany(const AIds: array of string): ISearchHits;
    function Search(const AText: string): ISearchQuery;
    function ListIds(const AFilter: ISearchFilter = nil): TArray<string>;
    procedure SetSynonyms(const AGroups: array of TSearchSynonym);
    function ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
  end;

  TMeilisearchWrite = class(TInterfacedObject, ISearchWrite)
  private
    FEngineRef: IMeilisearchEngine;
    FEngine: TMeilisearchEngine;
    FHasTask: Boolean;
    FTaskUid: Int64;
    FIds: TArray<string>;
    FByFilter: Boolean;
    FDone: Boolean;
    FTask: TMeilisearchTask;
    procedure RaiseIfFailed;
  public
    /// AHasTask False: nothing was sent (an empty write), done at once.
    constructor Create(AEngine: TMeilisearchEngine; AHasTask: Boolean; ATaskUid: Int64;
      const AIds: TArray<string>; AByFilter: Boolean);
    procedure WaitFor(ATimeoutMs: Integer = 0);
    function Pending: Boolean;
  end;

{ helpers }

function MeilisearchQuote(const AValue: string): string;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(AValue) do
  begin
    if (AValue[I] = '\') or (AValue[I] = '"') then
      Result := Result + '\';
    Result := Result + AValue[I];
  end;
  Result := Result + '"';
end;

function FilterValue(const AValue: TSearchValue): string;
begin
  if AValue.Kind = svString then
    Result := MeilisearchQuote(AValue.AsString)
  else
    Result := AValue.ToFilterText;
end;

function FilterValueList(const AFilter: ISearchFilter): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to AFilter.ValueCount - 1 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + FilterValue(AFilter.Value(I));
  end;
  Result := Result + ']';
end;

function FilterGroup(const AFilter: ISearchFilter; const AJoin: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AFilter.ChildCount - 1 do
  begin
    if I > 0 then
      Result := Result + AJoin;
    Result := Result + '(' + MeilisearchFilterText(AFilter.Child(I)) + ')';
  end;
end;

function MeilisearchFilterText(const AFilter: ISearchFilter): string;
var
  LField: string;
begin
  if AFilter = nil then
    Exit('');
  LField := AFilter.Field;
  case AFilter.Op of
    fopEq: Result := LField + ' = ' + FilterValue(AFilter.Value(0));
    fopNotEq: Result := LField + ' != ' + FilterValue(AFilter.Value(0));
    fopAnyOf: Result := LField + ' IN ' + FilterValueList(AFilter);
    fopNoneOf: Result := LField + ' NOT IN ' + FilterValueList(AFilter);
    fopGt: Result := LField + ' > ' + FilterValue(AFilter.Value(0));
    fopGe: Result := LField + ' >= ' + FilterValue(AFilter.Value(0));
    fopLt: Result := LField + ' < ' + FilterValue(AFilter.Value(0));
    fopLe: Result := LField + ' <= ' + FilterValue(AFilter.Value(0));
    fopBetween: Result := LField + ' ' + FilterValue(AFilter.Value(0)) + ' TO ' +
      FilterValue(AFilter.Value(1));
    fopAll: Result := FilterGroup(AFilter, ' AND ');
    fopAny: Result := FilterGroup(AFilter, ' OR ');
  else
    raise ESearchNotSupported.CreateFmt('Meilisearch: no syntax for the filter "%s".',
      [SearchFilterOpName(AFilter.Op)]);
  end;
end;

function Seg(const AText: string): string;
begin
  Result := PcPercentEncode(AText);
end;

function IsSuccess(AStatus: Integer): Boolean;
begin
  Result := (AStatus >= 200) and (AStatus <= 299);
end;

function ParseBody(const ABody, AWhat: string): TJsonValue;
begin
  Result := SearchParseAnswer(ABody, ENGINE_NAME + ' ' + AWhat);
end;

function MeilisearchSynonymsJson(const AGroups: array of TSearchSynonym): string;
var
  LKeys: TArray<string>;
  LValues: TArray<TArray<string>>;
  W: TJsonWriter;
  I, J, K: Integer;

  procedure Add(const AKey, AWord: string);
  var
    X, Y: Integer;
  begin
    for X := 0 to High(LKeys) do
      if LKeys[X] = AKey then
      begin
        for Y := 0 to High(LValues[X]) do
          if LValues[X][Y] = AWord then
            Exit;
        SetLength(LValues[X], Length(LValues[X]) + 1);
        LValues[X][High(LValues[X])] := AWord;
        Exit;
      end;
    SetLength(LKeys, Length(LKeys) + 1);
    SetLength(LValues, Length(LValues) + 1);
    LKeys[High(LKeys)] := AKey;
    SetLength(LValues[High(LValues)], 1);
    LValues[High(LValues)][0] := AWord;
  end;

begin
  LKeys := nil;
  LValues := nil;
  for I := 0 to High(AGroups) do
    if AGroups[I].IsOneWay then
    begin
      for J := 0 to High(AGroups[I].Words) do
        Add(AGroups[I].Root, AGroups[I].Words[J]);
    end
    else
      for J := 0 to High(AGroups[I].Words) do
        for K := 0 to High(AGroups[I].Words) do
          if J <> K then
            Add(AGroups[I].Words[J], AGroups[I].Words[K]);
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    for I := 0 to High(LKeys) do
      SearchWriteStrings(W, LKeys[I], LValues[I]);
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function StringsJson(const AItems: array of string): string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W := TJsonWriter.Create;
  try
    W.BeginArray;
    for I := 0 to High(AItems) do
      W.WriteString(AItems[I]);
    W.EndArray;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

{ TMeilisearchTypoTolerance }

class function TMeilisearchTypoTolerance.Standard: TMeilisearchTypoTolerance;
begin
  Result := Default(TMeilisearchTypoTolerance);
  Result.Enabled := True;
  Result.OneTypo := 5;
  Result.TwoTypos := 9;
end;

{ TMeilisearchConfig }

class function TMeilisearchConfig.Create(const AUrl, AApiKey: string): TMeilisearchConfig;
begin
  Result := Default(TMeilisearchConfig);
  Result.Url := AUrl;
  Result.ApiKey := AApiKey;
end;

{ TMeilisearchTask }

function TMeilisearchTask.Finished: Boolean;
begin
  Result := (Status <> 'enqueued') and (Status <> 'processing');
end;

{ TMeilisearchEngine }

class function TMeilisearchEngine.New(const AConfig: TMeilisearchConfig): IMeilisearchEngine;
begin
  Result := New(AConfig, nil);
end;

class function TMeilisearchEngine.New(const AConfig: TMeilisearchConfig;
  const ATransport: IPcHttpTransport): IMeilisearchEngine;
begin
  Result := TMeilisearchEngine.Create(AConfig, ATransport);
end;

constructor TMeilisearchEngine.Create(const AConfig: TMeilisearchConfig;
  const ATransport: IPcHttpTransport);
var
  LUrl: TPcHttpUrl;
  LInner: IPcHttpTransport;
  LPollOptions: TPcHttpTelemetryOptions;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FConfig := AConfig;
  FBase := AConfig.Url;
  while (FBase <> '') and (FBase[Length(FBase)] = '/') do
    SetLength(FBase, Length(FBase) - 1);
  try
    LUrl := PcParseHttpUrl(FBase);
  except
    on E: EArgumentException do
      raise ESearchArgumentError.CreateFmt('%s: invalid URL "%s": %s', [ENGINE_NAME, AConfig.Url, E.Message]);
  end;
  if LUrl.Target <> '/' then
    raise ESearchArgumentError.CreateFmt('%s: the URL is the server only, without a path or query (got "%s").',
      [ENGINE_NAME, AConfig.Url]);
  if ATransport <> nil then
    LInner := ATransport
  else
    LInner := PcNewHttpTransport(AConfig.Http);
  // Every call is a client span under the current one and a duration on
  // PcMetrics; the task polls only the duration (design, section 13).
  FTransport := PcNewTracedHttpTransport(LInner);
  LPollOptions := Default(TPcHttpTelemetryOptions);
  LPollOptions.NoSpans := True;
  FPollTransport := PcNewTracedHttpTransport(LInner, LPollOptions);
end;

destructor TMeilisearchEngine.Destroy;
begin
  FPollTransport := nil;
  FTransport := nil;
  FLock.Free;
  inherited Destroy;
end;

function TMeilisearchEngine.Config: TMeilisearchConfig;
begin
  Result := FConfig;
end;

function TMeilisearchEngine.WaitLimit(ATimeoutMs: Integer): Integer;
begin
  if ATimeoutMs > 0 then
    Result := ATimeoutMs
  else if FConfig.WaitTimeoutMs > 0 then
    Result := FConfig.WaitTimeoutMs
  else
    Result := MEILISEARCH_DEFAULT_WAIT_MS;
end;

function TMeilisearchEngine.Exchange(const AMethod, APath, ABody: string): TPcHttpResponse;
begin
  Result := Exchange(FTransport, AMethod, APath, ABody);
end;

function TMeilisearchEngine.Exchange(const ATransport: IPcHttpTransport;
  const AMethod, APath, ABody: string): TPcHttpResponse;
var
  LRequest: TPcHttpRequest;
begin
  LRequest := TPcHttpRequest.Create(AMethod, FBase + APath);
  LRequest.TimeoutMs := FConfig.TimeoutMs;
  if FConfig.ApiKey <> '' then
    LRequest.AddHeader('Authorization', 'Bearer ' + FConfig.ApiKey);
  if PcHttpMethodHasBody(AMethod) then
  begin
    LRequest.AddHeader('Content-Type', 'application/json');
    LRequest.Body := ABody;
  end;
  try
    Result := ATransport.Send(LRequest);
  except
    on E: EPcHttpTransport do
      raise ESearchUnavailable.CreateEngine(Format('%s: no answer: %s', [ENGINE_NAME, E.Message]), 0, '', '');
    on E: EPcTextEncoding do
      raise ESearchUnavailable.CreateEngine(Format('%s %s %s: the answer isn''t UTF-8 (%s).',
        [ENGINE_NAME, AMethod, APath, E.Message]), 0, '', '');
    on E: EArgumentException do
      raise ESearchArgumentError.CreateFmt('%s %s %s: %s', [ENGINE_NAME, AMethod, APath, E.Message]);
  end;
end;

procedure TMeilisearchEngine.RaiseAnswer(const AMethod, APath: string;
  const AResponse: TPcHttpResponse);
var
  LJson: TJsonValue;
  LCode, LMessage, LText: string;
begin
  LCode := '';
  LMessage := '';
  try
    LJson := ParseJson(AResponse.Body);
    try
      LCode := SearchJsonText(LJson, 'code');
      LMessage := SearchJsonText(LJson, 'message');
    finally
      LJson.Free;
    end;
  except
    on EJsonError do
      LMessage := Copy(Trim(AResponse.Body), 1, 200);
  end;
  LText := Format('%s %s %s: HTTP %d', [ENGINE_NAME, AMethod, PcUrlWithoutQuery(APath), AResponse.Status]);
  if LCode <> '' then
    LText := LText + ' ' + LCode;
  if LMessage <> '' then
    LText := LText + ': ' + LMessage;
  case AResponse.Status of
    401, 403:
      raise ESearchAuthError.CreateEngine(LText, AResponse.Status, LCode, LMessage);
    404:
      if LCode = 'index_not_found' then
        raise ESearchIndexNotFound.CreateEngine(LText, AResponse.Status, LCode, LMessage)
      else
        raise ESearchRequestError.CreateEngine(LText, AResponse.Status, LCode, LMessage);
    400, 402, 405..499:
      raise ESearchRequestError.CreateEngine(LText, AResponse.Status, LCode, LMessage);
    500..599:
      raise ESearchUnavailable.CreateEngine(LText, AResponse.Status, LCode, LMessage);
  else
    raise ESearchError.CreateEngine(LText, AResponse.Status, LCode, LMessage);
  end;
end;

function TMeilisearchEngine.Call(const AMethod, APath, ABody: string): string;
begin
  Result := Call(FTransport, AMethod, APath, ABody);
end;

function TMeilisearchEngine.Call(const ATransport: IPcHttpTransport;
  const AMethod, APath, ABody: string): string;
var
  LResponse: TPcHttpResponse;
begin
  LResponse := Exchange(ATransport, AMethod, APath, ABody);
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer(AMethod, APath, LResponse);
  Result := LResponse.Body;
end;

// The taskUid of a write's answer (202 {"taskUid": N, ...}).
function TaskUidOf(const ABody, AWhat: string): Int64;
var
  LJson, V: TJsonValue;
begin
  LJson := ParseBody(ABody, AWhat);
  try
    V := nil;
    if LJson.Kind = jkObject then
      V := LJson.Find('taskUid');
    if (V = nil) or not V.TryAsInt64(Result) then
      raise ESearchUnavailable.CreateEngine(Format('%s %s: the answer has no taskUid.',
        [ENGINE_NAME, AWhat]), 0, '', '');
  finally
    LJson.Free;
  end;
end;

function TMeilisearchEngine.StartTask(const AMethod, APath, ABody: string): Int64;
begin
  Result := TaskUidOf(Call(AMethod, APath, ABody), AMethod + ' ' + APath);
end;

function TMeilisearchEngine.ReadTask(ATaskUid: Int64; APoll: Boolean): TMeilisearchTask;
var
  LPath: string;
  LJson, LError: TJsonValue;
  LTransport: IPcHttpTransport;
begin
  LPath := '/tasks/' + IntToStr(ATaskUid);
  if APoll then
    LTransport := FPollTransport
  else
    LTransport := FTransport;
  LJson := ParseBody(Call(LTransport, 'GET', LPath, ''), 'GET ' + LPath);
  try
    Result := Default(TMeilisearchTask);
    Result.Uid := ATaskUid;
    Result.Status := SearchJsonText(LJson, 'status');
    if Result.Status = '' then
      raise ESearchUnavailable.CreateEngine(Format('%s GET %s: the answer has no status.',
        [ENGINE_NAME, LPath]), 0, '', '');
    LError := LJson.Find('error');
    if (LError <> nil) and (LError.Kind = jkObject) then
    begin
      Result.ErrorCode := SearchJsonText(LError, 'code');
      Result.ErrorType := SearchJsonText(LError, 'type');
      Result.ErrorMessage := SearchJsonText(LError, 'message');
    end;
    if (Result.Status = 'canceled') and (Result.ErrorCode = '') then
    begin
      Result.ErrorCode := 'task_canceled';
      Result.ErrorMessage := 'The task was canceled.';
    end;
  finally
    LJson.Free;
  end;
end;

function TMeilisearchEngine.PollTask(ATaskUid: Int64; ALimit: Integer;
  out APolls: Integer): TMeilisearchTask;
var
  LStart: UInt64;
  LDelay: Cardinal;
begin
  LStart := TTicker.NowMs;
  LDelay := POLL_FIRST_MS;
  APolls := 1;
  Result := ReadTask(ATaskUid, True);
  while not Result.Finished do
  begin
    if TTicker.ElapsedMs(LStart) >= UInt64(ALimit) then
      raise ESearchTimeout.CreateEngine(Format('%s: task %d still %s after %d ms.',
        [ENGINE_NAME, ATaskUid, Result.Status, ALimit]), 0, '', '');
    TSleep.Sleep(LDelay);
    if LDelay < POLL_MAX_MS then
    begin
      LDelay := LDelay * 2;
      if LDelay > POLL_MAX_MS then
        LDelay := POLL_MAX_MS;
    end;
    Inc(APolls);
    Result := ReadTask(ATaskUid, True);
  end;
end;

// The polls make no span of their own: under a current span, the wait is
// one internal span, meilisearch.wait_task (design, section 13).
function TMeilisearchEngine.AwaitTask(ATaskUid: Int64; ATimeoutMs: Integer): TMeilisearchTask;
var
  LLimit, LPolls: Integer;
  LSpan: IPcSpan;
begin
  LLimit := WaitLimit(ATimeoutMs);
  if TPcTracing.Current = nil then
  begin
    Result := PollTask(ATaskUid, LLimit, LPolls);
    Exit;
  end;
  LPolls := 0;
  LSpan := TPcTracing.StartSpan(MEILISEARCH_WAIT_SPAN, skInternal);
  try
    LSpan.SetIntAttribute('meilisearch.task.uid', ATaskUid);
    try
      Result := PollTask(ATaskUid, LLimit, LPolls);
      LSpan.SetIntAttribute('meilisearch.task.polls', LPolls);
      LSpan.SetAttribute('meilisearch.task.status', Result.Status);
      if Result.Status <> 'succeeded' then
      begin
        LSpan.SetAttribute('error.type', Result.ErrorCode);
        LSpan.SetStatus(ssError, Result.ErrorMessage);
      end;
    except
      on E: Exception do
      begin
        LSpan.SetIntAttribute('meilisearch.task.polls', LPolls);
        LSpan.SetAttribute('error.type', E.ClassName);
        LSpan.SetStatus(ssError, E.Message);
        raise;
      end;
    end;
  finally
    LSpan.Finish;
  end;
end;

procedure TMeilisearchEngine.RaiseTask(const ATask: TMeilisearchTask; const AWhat: string);
var
  LText: string;
begin
  if ATask.Status = 'succeeded' then
    Exit;
  LText := Format('%s: %s: task %d %s', [ENGINE_NAME, AWhat, ATask.Uid, ATask.Status]);
  if ATask.ErrorCode <> '' then
    LText := LText + ' ' + ATask.ErrorCode;
  if ATask.ErrorMessage <> '' then
    LText := LText + ': ' + ATask.ErrorMessage;
  if ATask.ErrorCode = 'index_not_found' then
    raise ESearchIndexNotFound.CreateEngine(LText, 0, ATask.ErrorCode, ATask.ErrorMessage);
  if ATask.ErrorType = 'auth' then
    raise ESearchAuthError.CreateEngine(LText, 0, ATask.ErrorCode, ATask.ErrorMessage);
  if (ATask.ErrorType = 'internal') or (ATask.ErrorType = 'system') then
    raise ESearchUnavailable.CreateEngine(LText, 0, ATask.ErrorCode, ATask.ErrorMessage);
  raise ESearchRequestError.CreateEngine(LText, 0, ATask.ErrorCode, ATask.ErrorMessage);
end;

function TMeilisearchEngine.Send(const AMethod, APath, ABody: string): string;
begin
  Result := Call(AMethod, APath, ABody);
end;

procedure TMeilisearchEngine.WaitForTask(ATaskUid: Int64; ATimeoutMs: Integer);
begin
  RaiseTask(AwaitTask(ATaskUid, ATimeoutMs), 'task');
end;

function TMeilisearchEngine.FindIndexInfo(const AName: string; out APrimaryKey: string): Boolean;
var
  LPath: string;
  LResponse: TPcHttpResponse;
  LJson: TJsonValue;
begin
  APrimaryKey := '';
  LPath := '/indexes/' + Seg(AName);
  LResponse := Exchange('GET', LPath, '');
  if LResponse.Status = 404 then
  begin
    // Only index_not_found means "no index"; another 404 is an error.
    try
      RaiseAnswer('GET', LPath, LResponse);
    except
      on ESearchIndexNotFound do
        Exit(False);
    end;
  end;
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer('GET', LPath, LResponse);
  LJson := ParseBody(LResponse.Body, 'GET ' + LPath);
  try
    APrimaryKey := SearchJsonText(LJson, 'primaryKey');
  finally
    LJson.Free;
  end;
  Result := True;
end;

procedure TMeilisearchEngine.RequireIndex(const AName: string);
var
  LKey: string;
begin
  if not FindIndexInfo(AName, LKey) then
    raise ESearchIndexNotFound.CreateEngine(Format('%s: index "%s" not found; EnsureIndex it first.',
      [ENGINE_NAME, AName]), 404, 'index_not_found', '');
end;

function TMeilisearchEngine.CachedMaxHits(const AName: string; out AValue: Integer): Boolean;
var
  I, LLimit: Integer;
begin
  LLimit := FConfig.CacheMs;
  if LLimit <= 0 then
    LLimit := MEILISEARCH_DEFAULT_CACHE_MS;
  FLock.Enter;
  try
    for I := 0 to High(FMaxHitsNames) do
      if (FMaxHitsNames[I] = AName) and (TTicker.ElapsedMs(FMaxHitsAt[I]) < UInt64(LLimit)) then
      begin
        AValue := FMaxHitsValues[I];
        Exit(True);
      end;
    AValue := 0;
    Result := False;
  finally
    FLock.Leave;
  end;
end;

procedure TMeilisearchEngine.CacheMaxHits(const AName: string; AValue: Integer);
var
  I, N: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FMaxHitsNames) do
      if FMaxHitsNames[I] = AName then
      begin
        FMaxHitsValues[I] := AValue;
        FMaxHitsAt[I] := TTicker.NowMs;
        Exit;
      end;
    N := Length(FMaxHitsNames);
    SetLength(FMaxHitsNames, N + 1);
    SetLength(FMaxHitsValues, N + 1);
    SetLength(FMaxHitsAt, N + 1);
    FMaxHitsNames[N] := AName;
    FMaxHitsValues[N] := AValue;
    FMaxHitsAt[N] := TTicker.NowMs;
  finally
    FLock.Leave;
  end;
end;

procedure TMeilisearchEngine.ForgetMaxHits(const AName: string);
var
  I, J: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FMaxHitsNames) do
      if FMaxHitsNames[I] = AName then
      begin
        for J := I to High(FMaxHitsNames) - 1 do
        begin
          FMaxHitsNames[J] := FMaxHitsNames[J + 1];
          FMaxHitsValues[J] := FMaxHitsValues[J + 1];
          FMaxHitsAt[J] := FMaxHitsAt[J + 1];
        end;
        SetLength(FMaxHitsNames, Length(FMaxHitsNames) - 1);
        SetLength(FMaxHitsValues, Length(FMaxHitsValues) - 1);
        SetLength(FMaxHitsAt, Length(FMaxHitsAt) - 1);
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

function TMeilisearchEngine.MaxHitsOf(const AName: string): Integer;
var
  LPath: string;
  LJson, V: TJsonValue;
  LValue: Int64;
begin
  if CachedMaxHits(AName, Result) then
    Exit;
  LPath := '/indexes/' + Seg(AName) + '/settings/pagination';
  LJson := ParseBody(Call('GET', LPath, ''), 'GET ' + LPath);
  try
    V := nil;
    if LJson.Kind = jkObject then
      V := LJson.Find('maxTotalHits');
    if (V = nil) or not V.TryAsInt64(LValue) then
      raise ESearchUnavailable.CreateEngine(Format('%s GET %s: the answer has no maxTotalHits.',
        [ENGINE_NAME, LPath]), 0, '', '');
  finally
    LJson.Free;
  end;
  if LValue > MaxInt then
    LValue := MaxInt;
  Result := Integer(LValue);
  CacheMaxHits(AName, Result);
end;

function SettingsJson(const ASchema: ISearchSchema): string;
var
  W: TJsonWriter;
  LSearchable, LFilterable, LSortable: TArray<string>;
  LField: TSearchField;
  I: Integer;

  procedure Add(var AList: TArray<string>; const AName: string);
  begin
    SetLength(AList, Length(AList) + 1);
    AList[High(AList)] := AName;
  end;

begin
  LSearchable := nil;
  LSortable := nil;
  LFilterable := nil;
  Add(LFilterable, 'id');
  for I := 0 to ASchema.FieldCount - 1 do
  begin
    LField := ASchema.Field(I);
    if LField.IsSearchable then
      Add(LSearchable, LField.Name);
    if LField.IsFilterable then
      Add(LFilterable, LField.Name);
    if LField.IsSortable then
      Add(LSortable, LField.Name);
  end;
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    SearchWriteStrings(W, 'searchableAttributes', LSearchable);
    SearchWriteStrings(W, 'filterableAttributes', LFilterable);
    SearchWriteStrings(W, 'sortableAttributes', LSortable);
    W.Name('pagination');
    W.BeginObject;
    W.Name('maxTotalHits');
    W.WriteInt64(ASchema.MaxHits);
    W.EndObject;
    // Meilisearch keeps maxValuesPerFacet (100) values of a facet: by count,
    // the ones kept are the most frequent.
    W.Name('faceting');
    W.BeginObject;
    W.Name('sortFacetValuesBy');
    W.BeginObject;
    W.Name('*');
    W.WriteString('count');
    W.EndObject;
    W.EndObject;
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function TMeilisearchEngine.EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
var
  LKey, LBody, LPath: string;
  W: TJsonWriter;
  LTask: TMeilisearchTask;
begin
  if ASchema = nil then
    raise ESearchArgumentError.Create('EnsureIndex: the schema is nil.');
  LPath := '/indexes/' + Seg(ASchema.Name);
  if FindIndexInfo(ASchema.Name, LKey) then
  begin
    if (LKey <> '') and (LKey <> 'id') then
      raise ESearchSchemaError.CreateEngine(Format('%s: index "%s" has the primary key "%s", not "id"; ' +
        'drop and rebuild the index.', [ENGINE_NAME, ASchema.Name, LKey]), 0, '', '');
  end
  else
  begin
    W := TJsonWriter.Create;
    try
      W.BeginObject;
      W.Name('uid');
      W.WriteString(ASchema.Name);
      W.Name('primaryKey');
      W.WriteString('id');
      W.EndObject;
      LBody := W.ToString;
    finally
      W.Free;
    end;
    LTask := AwaitTask(StartTask('POST', '/indexes', LBody), 0);
    // Created meanwhile by someone else: that is what was asked.
    if LTask.ErrorCode <> 'index_already_exists' then
      RaiseTask(LTask, 'create index "' + ASchema.Name + '"');
  end;
  RaiseTask(AwaitTask(StartTask('PATCH', LPath + '/settings', SettingsJson(ASchema)), 0),
    'settings of index "' + ASchema.Name + '"');
  CacheMaxHits(ASchema.Name, ASchema.MaxHits);
  Result := TMeilisearchIndex.Create(Self, ASchema.Name);
end;

function TMeilisearchEngine.Index(const AName: string): ISearchIndex;
begin
  SearchCheckIndexName(AName);
  Result := TMeilisearchIndex.Create(Self, AName);
end;

function TMeilisearchEngine.IndexExists(const AName: string): Boolean;
var
  LKey: string;
begin
  SearchCheckIndexName(AName);
  Result := FindIndexInfo(AName, LKey);
end;

procedure TMeilisearchEngine.DropIndex(const AName: string);
var
  LPath: string;
  LResponse: TPcHttpResponse;
  LTask: TMeilisearchTask;
begin
  SearchCheckIndexName(AName);
  ForgetMaxHits(AName);
  LPath := '/indexes/' + Seg(AName);
  LResponse := Exchange('DELETE', LPath, '');
  if LResponse.Status = 404 then
  begin
    try
      RaiseAnswer('DELETE', LPath, LResponse);
    except
      on ESearchIndexNotFound do
        Exit;
    end;
  end;
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer('DELETE', LPath, LResponse);
  LTask := AwaitTask(TaskUidOf(LResponse.Body, 'DELETE ' + LPath), 0);
  if LTask.ErrorCode <> 'index_not_found' then
    RaiseTask(LTask, 'drop index "' + AName + '"');
end;

procedure TMeilisearchEngine.ReplaceIndex(const ATarget, ASource: string);
var
  LKey, LBody: string;
  LTargetExists: Boolean;
  W: TJsonWriter;
begin
  SearchCheckIndexName(ATarget);
  SearchCheckIndexName(ASource);
  if ATarget = ASource then
    raise ESearchArgumentError.CreateFmt('ReplaceIndex: "%s" can''t replace itself.', [ATarget]);
  RequireIndex(ASource);
  LTargetExists := FindIndexInfo(ATarget, LKey);
  W := TJsonWriter.Create;
  try
    W.BeginArray;
    W.BeginObject;
    W.Name('indexes');
    W.BeginArray;
    // A swap is symmetric; a rename goes from the first to the second.
    if LTargetExists then
    begin
      W.WriteString(ATarget);
      W.WriteString(ASource);
    end
    else
    begin
      W.WriteString(ASource);
      W.WriteString(ATarget);
    end;
    W.EndArray;
    if not LTargetExists then
    begin
      W.Name('rename');
      W.WriteBoolean(True);
    end;
    W.EndObject;
    W.EndArray;
    LBody := W.ToString;
  finally
    W.Free;
  end;
  ForgetMaxHits(ATarget);
  ForgetMaxHits(ASource);
  RaiseTask(AwaitTask(StartTask('POST', '/swap-indexes', LBody), 0),
    Format('replace index "%s" with "%s"', [ATarget, ASource]));
  // After a swap the source holds what the target held.
  if LTargetExists then
    DropIndex(ASource);
end;

procedure TMeilisearchEngine.PutSetting(const AIndexName, ASetting, AMethod, ABody: string);
begin
  SearchCheckIndexName(AIndexName);
  // A settings call on a missing index would create it, without the schema.
  RequireIndex(AIndexName);
  RaiseTask(AwaitTask(StartTask(AMethod, '/indexes/' + Seg(AIndexName) + '/settings/' + ASetting, ABody), 0),
    Format('%s of index "%s"', [ASetting, AIndexName]));
end;

procedure TMeilisearchEngine.SetTypoTolerance(const AIndexName: string;
  const AValue: TMeilisearchTypoTolerance);
var
  W: TJsonWriter;
  LBody: string;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('enabled');
    W.WriteBoolean(AValue.Enabled);
    W.Name('minWordSizeForTypos');
    W.BeginObject;
    W.Name('oneTypo');
    W.WriteInt64(AValue.OneTypo);
    W.Name('twoTypos');
    W.WriteInt64(AValue.TwoTypos);
    W.EndObject;
    SearchWriteStrings(W, 'disableOnWords', AValue.DisableOnWords);
    SearchWriteStrings(W, 'disableOnAttributes', AValue.DisableOnAttributes);
    W.EndObject;
    LBody := W.ToString;
  finally
    W.Free;
  end;
  PutSetting(AIndexName, 'typo-tolerance', 'PATCH', LBody);
end;

procedure TMeilisearchEngine.SetRankingRules(const AIndexName: string; const ARules: array of string);
begin
  PutSetting(AIndexName, 'ranking-rules', 'PUT', StringsJson(ARules));
end;

procedure TMeilisearchEngine.SetStopWords(const AIndexName: string; const AWords: array of string);
begin
  PutSetting(AIndexName, 'stop-words', 'PUT', StringsJson(AWords));
end;

{ TMeilisearchIndex }

constructor TMeilisearchIndex.Create(AEngine: TMeilisearchEngine; const AName: string);
begin
  inherited Create;
  FEngine := AEngine;
  FEngineRef := AEngine;
  FName := AName;
  FPath := '/indexes/' + Seg(AName);
end;

function TMeilisearchIndex.Name: string;
begin
  Result := FName;
end;

function TMeilisearchIndex.NewWrite(ATaskUid: Int64; const AIds: TArray<string>;
  AByFilter: Boolean): ISearchWrite;
begin
  Result := TMeilisearchWrite.Create(FEngine, ATaskUid >= 0, ATaskUid, AIds, AByFilter);
end;

function TMeilisearchIndex.Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
var
  LIds: TArray<string>;
  LBody: string;
  I: Integer;
begin
  for I := 0 to High(ADocs) do
    if ADocs[I] = nil then
      raise ESearchArgumentError.CreateFmt('Upsert: document %d is nil.', [I]);
  LIds := nil;
  SetLength(LIds, Length(ADocs));
  LBody := '[';
  for I := 0 to High(ADocs) do
  begin
    LIds[I] := ADocs[I].Id;
    if I > 0 then
      LBody := LBody + ',';
    LBody := LBody + ADocs[I].ToJson;
  end;
  LBody := LBody + ']';
  FEngine.RequireIndex(FName);
  if Length(ADocs) = 0 then
    Exit(NewWrite(-1, nil, False));
  Result := NewWrite(FEngine.StartTask('POST', FPath + '/documents?primaryKey=id', LBody), LIds, False);
end;

function TMeilisearchIndex.Delete(const AIds: array of string): ISearchWrite;
var
  LIds: TArray<string>;
  W: TJsonWriter;
  LBody: string;
  I: Integer;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  LIds := nil;
  SetLength(LIds, Length(AIds));
  W := TJsonWriter.Create;
  try
    W.BeginArray;
    for I := 0 to High(AIds) do
    begin
      LIds[I] := AIds[I];
      W.WriteString(AIds[I]);
    end;
    W.EndArray;
    LBody := W.ToString;
  finally
    W.Free;
  end;
  FEngine.RequireIndex(FName);
  if Length(AIds) = 0 then
    Exit(NewWrite(-1, nil, False));
  Result := NewWrite(FEngine.StartTask('POST', FPath + '/documents/delete-batch', LBody), LIds, False);
end;

function TMeilisearchIndex.DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
var
  W: TJsonWriter;
  LBody: string;
begin
  if AFilter = nil then
    raise ESearchArgumentError.Create('DeleteWhere: the filter is nil.');
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('filter');
    W.WriteString(MeilisearchFilterText(AFilter));
    W.EndObject;
    LBody := W.ToString;
  finally
    W.Free;
  end;
  FEngine.RequireIndex(FName);
  Result := NewWrite(FEngine.StartTask('POST', FPath + '/documents/delete', LBody), nil, True);
end;

function TMeilisearchIndex.Get(const AId: string): ISearchHit;
var
  LPath: string;
  LResponse: TPcHttpResponse;
begin
  SearchCheckId(AId);
  LPath := FPath + '/documents/' + Seg(AId);
  LResponse := FEngine.Exchange('GET', LPath, '');
  if LResponse.Status = 404 then
  begin
    // document_not_found is "no such document"; index_not_found raises.
    try
      FEngine.RaiseAnswer('GET', LPath, LResponse);
    except
      on E: ESearchRequestError do
        if E.EngineCode = 'document_not_found' then
          Exit(nil)
        else
          raise;
    end;
  end;
  if not IsSuccess(LResponse.Status) then
    FEngine.RaiseAnswer('GET', LPath, LResponse);
  Result := TSearchHit.Create(AId, ParseBody(LResponse.Body, 'GET ' + LPath));
end;

function TMeilisearchIndex.GetMany(const AIds: array of string): ISearchHits;
var
  LList: TSearchHitList;
  LWanted: TArray<string>;
  W: TJsonWriter;
  LBody: string;
  LJson, LResults, LDoc: TJsonValue;
  I, J: Integer;
  LKnown: Boolean;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  LList := TSearchHitList.Create;
  Result := LList;
  if Length(AIds) = 0 then
  begin
    FEngine.RequireIndex(FName);
    Exit;
  end;
  // Each id once in the request; the answer is put back in the order asked.
  LWanted := nil;
  for I := 0 to High(AIds) do
  begin
    LKnown := False;
    for J := 0 to High(LWanted) do
      if LWanted[J] = AIds[I] then
        LKnown := True;
    if not LKnown then
    begin
      SetLength(LWanted, Length(LWanted) + 1);
      LWanted[High(LWanted)] := AIds[I];
    end;
  end;
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    SearchWriteStrings(W, 'ids', LWanted);
    W.Name('limit');
    W.WriteInt64(Length(LWanted));
    W.EndObject;
    LBody := W.ToString;
  finally
    W.Free;
  end;
  LJson := ParseBody(FEngine.Call('POST', FPath + '/documents/fetch', LBody), 'POST documents/fetch');
  try
    LResults := nil;
    if LJson.Kind = jkObject then
      LResults := LJson.Find('results');
    if (LResults = nil) or (LResults.Kind <> jkArray) then
      raise ESearchUnavailable.CreateEngine(Format('%s POST %s/documents/fetch: the answer has no results.',
        [ENGINE_NAME, FPath]), 0, '', '');
    for I := 0 to High(AIds) do
      for J := 0 to LResults.Count - 1 do
      begin
        LDoc := LResults.Items[J];
        if (LDoc.Kind = jkObject) and (SearchJsonId(LDoc.Find('id')) = AIds[I]) then
        begin
          LList.AddHit(AIds[I], SearchCloneJson(LDoc));
          Break;
        end;
      end;
  finally
    LJson.Free;
  end;
end;

function TMeilisearchIndex.Search(const AText: string): ISearchQuery;
begin
  Result := TSearchQuery.Create(Self, AText);
end;

function TMeilisearchIndex.ListIds(const AFilter: ISearchFilter): TArray<string>;
var
  W: TJsonWriter;
  LJson, LResults: TJsonValue;
  LOffset, LCount, I: Integer;
begin
  Result := nil;
  LCount := 0;
  LOffset := 0;
  repeat
    W := TJsonWriter.Create;
    try
      W.BeginObject;
      W.Name('offset');
      W.WriteInt64(LOffset);
      W.Name('limit');
      W.WriteInt64(LIST_PAGE);
      SearchWriteStrings(W, 'fields', ['id']);
      if AFilter <> nil then
      begin
        W.Name('filter');
        W.WriteString(MeilisearchFilterText(AFilter));
      end;
      W.EndObject;
      LJson := ParseBody(FEngine.Call('POST', FPath + '/documents/fetch', W.ToString), 'POST documents/fetch');
    finally
      W.Free;
    end;
    try
      LResults := SearchJsonMember(LJson, 'results');
      if (LResults = nil) or (LResults.Kind <> jkArray) then
        raise ESearchUnavailable.CreateEngine(Format('%s POST %s/documents/fetch: the answer has no results.',
          [ENGINE_NAME, FPath]), 0, '', '');
      if LCount + LResults.Count > Length(Result) then
        SetLength(Result, LCount + LResults.Count);
      for I := 0 to LResults.Count - 1 do
      begin
        Result[LCount] := SearchJsonId(SearchJsonMember(LResults.Items[I], 'id'));
        Inc(LCount);
      end;
      Inc(LOffset, LResults.Count);
      I := LResults.Count;
    finally
      LJson.Free;
    end;
  until I < LIST_PAGE;
  SetLength(Result, LCount);
end;

procedure TMeilisearchIndex.SetSynonyms(const AGroups: array of TSearchSynonym);
begin
  SearchCheckSynonyms(AGroups);
  FEngine.PutSetting(FName, 'synonyms', 'PUT', MeilisearchSynonymsJson(AGroups));
end;

function SearchJson(const ARequest: TSearchRequest): string;
var
  W: TJsonWriter;
  LRaw: TJsonValue;
  LFields: TArray<string>;
  I: Integer;
  LHasId: Boolean;

  // A Raw parameter of the same name replaces the library's.
  function Mine(const AName: string): Boolean;
  var
    X: Integer;
  begin
    for X := 0 to High(ARequest.Raw) do
      if ARequest.Raw[X].Name = AName then
        Exit(False);
    Result := True;
  end;

  procedure Sorts;
  var
    X: Integer;
  begin
    W.Name('sort');
    W.BeginArray;
    for X := 0 to High(ARequest.Sorts) do
      if ARequest.Sorts[X].Order = soDesc then
        W.WriteString(ARequest.Sorts[X].Field + ':desc')
      else
        W.WriteString(ARequest.Sorts[X].Field + ':asc');
    W.EndArray;
  end;

begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    if Mine('q') then
    begin
      W.Name('q');
      W.WriteString(ARequest.TextToSend);
    end;
    if Mine('matchingStrategy') then
    begin
      W.Name('matchingStrategy');
      if ARequest.Words = swRelaxed then
        W.WriteString('last')
      else
        W.WriteString('all');
    end;
    if (ARequest.Filter <> nil) and Mine('filter') then
    begin
      W.Name('filter');
      W.WriteString(MeilisearchFilterText(ARequest.Filter));
    end;
    if (Length(ARequest.Sorts) > 0) and Mine('sort') then
      Sorts;
    if Mine('page') then
    begin
      W.Name('page');
      W.WriteInt64(ARequest.Page);
    end;
    if Mine('hitsPerPage') then
    begin
      W.Name('hitsPerPage');
      W.WriteInt64(ARequest.PageSize);
    end;
    if (Length(ARequest.Facets) > 0) and Mine('facets') then
      SearchWriteStrings(W, 'facets', ARequest.Facets);
    if (Length(ARequest.Highlight) > 0) and Mine('attributesToHighlight') then
    begin
      SearchWriteStrings(W, 'attributesToHighlight', ARequest.Highlight);
      W.Name('highlightPreTag');
      W.WriteString(SEARCH_HIGHLIGHT_START);
      W.Name('highlightPostTag');
      W.WriteString(SEARCH_HIGHLIGHT_END);
    end;
    if (Length(ARequest.Fields) > 0) and Mine('attributesToRetrieve') then
    begin
      LFields := Copy(ARequest.Fields, 0, Length(ARequest.Fields));
      LHasId := False;
      for I := 0 to High(LFields) do
        if LFields[I] = 'id' then
          LHasId := True;
      if not LHasId then
      begin
        SetLength(LFields, Length(LFields) + 1);
        LFields[High(LFields)] := 'id';
      end;
      SearchWriteStrings(W, 'attributesToRetrieve', LFields);
    end;
    for I := 0 to High(ARequest.Raw) do
    begin
      LRaw := ParseJson(ARequest.Raw[I].JsonText);
      try
        W.Name(ARequest.Raw[I].Name);
        W.WriteValue(LRaw);
      finally
        LRaw.Free;
      end;
    end;
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function TMeilisearchIndex.ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
var
  LMaxHits: Integer;
  LText, LWhat: string;
  LJson, LHits, LHit, LDist, LValues, LFormatted, V: TJsonValue;
  LTotal: Int64;
  LResult: TSearchResult;
  LOut: TSearchHit;
  LFacet: TSearchFacet;
  LHighlight: TSearchHighlight;
  I, J: Integer;
begin
  if (ARequest.PageSize > 0) and (ARequest.Page > 1) then
  begin
    LMaxHits := FEngine.MaxHitsOf(FName);
    if Int64(ARequest.Page - 1) * ARequest.PageSize >= LMaxHits then
      raise ESearchArgumentError.CreateFmt('Page %d of %d starts past the index''s MaxHits (%d).',
        [ARequest.Page, ARequest.PageSize, LMaxHits]);
  end;
  LWhat := 'POST ' + FPath + '/search';
  LText := FEngine.Call('POST', FPath + '/search', SearchJson(ARequest));
  LJson := ParseBody(LText, LWhat);
  try
    if (LJson.Kind <> jkObject) or (LJson.Find('totalHits') = nil)
      or not LJson.Find('totalHits').TryAsInt64(LTotal) then
      raise ESearchUnavailable.CreateEngine(Format('%s %s: the answer has no totalHits.',
        [ENGINE_NAME, LWhat]), 0, '', '');
    LResult := TSearchResult.Create(LTotal, ARequest.Page, ARequest.PageSize, LText);
    Result := LResult;
    LHits := LJson.Find('hits');
    if (LHits <> nil) and (LHits.Kind = jkArray) then
      for I := 0 to LHits.Count - 1 do
      begin
        LHit := LHits.Items[I];
        LOut := LResult.AddHit(SearchJsonId(LHit.Find('id')), SearchCloneJsonWithout(LHit, '_formatted'));
        LFormatted := SearchJsonMember(LHit, '_formatted');
        if LFormatted <> nil then
          for J := 0 to High(ARequest.Highlight) do
          begin
            V := SearchJsonMember(LFormatted, ARequest.Highlight[J]);
            if (V <> nil) and (V.Kind = jkString)
              and SearchHighlightFromMarked(ARequest.Highlight[J], V.AsString, LHighlight) then
              LOut.AddHighlight(LHighlight);
          end;
      end;
    LDist := LJson.Find('facetDistribution');
    for I := 0 to High(ARequest.Facets) do
    begin
      LFacet := Default(TSearchFacet);
      LFacet.Field := ARequest.Facets[I];
      LValues := nil;
      if (LDist <> nil) and (LDist.Kind = jkObject) then
        LValues := LDist.Find(ARequest.Facets[I]);
      if (LValues <> nil) and (LValues.Kind = jkObject) then
      begin
        SetLength(LFacet.Values, LValues.Count);
        for J := 0 to LValues.Count - 1 do
        begin
          LFacet.Values[J].Value := LValues.Names[J];
          LFacet.Values[J].Count := LValues.Items[J].AsInt64;
        end;
      end;
      LResult.AddFacet(LFacet);
    end;
  finally
    LJson.Free;
  end;
end;

{ TMeilisearchWrite }

constructor TMeilisearchWrite.Create(AEngine: TMeilisearchEngine; AHasTask: Boolean;
  ATaskUid: Int64; const AIds: TArray<string>; AByFilter: Boolean);
begin
  inherited Create;
  FEngine := AEngine;
  FEngineRef := AEngine;
  FHasTask := AHasTask;
  FTaskUid := ATaskUid;
  FIds := AIds;
  FByFilter := AByFilter;
  FDone := not AHasTask;
  FTask := Default(TMeilisearchTask);
  if not AHasTask then
    FTask.Status := 'succeeded';
end;

procedure TMeilisearchWrite.RaiseIfFailed;
var
  LFailures: TSearchFailures;
  I: Integer;
begin
  if FTask.Status = 'succeeded' then
    Exit;
  // The index's absence, and a delete by filter (no documents to list), are
  // errors of the request; a refused batch of documents is a failed write.
  if FByFilter or (FTask.ErrorCode = 'index_not_found') then
    FEngine.RaiseTask(FTask, 'write');
  LFailures := nil;
  SetLength(LFailures, Length(FIds));
  for I := 0 to High(FIds) do
    LFailures[I] := TSearchFailure.Create(FIds[I], FTask.ErrorCode, FTask.ErrorMessage);
  raise ESearchWriteFailed.CreateFailures(LFailures, True);
end;

procedure TMeilisearchWrite.WaitFor(ATimeoutMs: Integer);
begin
  if not FDone then
  begin
    FTask := FEngine.AwaitTask(FTaskUid, ATimeoutMs);
    FDone := True;
  end;
  RaiseIfFailed;
end;

function TMeilisearchWrite.Pending: Boolean;
begin
  if not FDone then
  begin
    FTask := FEngine.ReadTask(FTaskUid);
    FDone := FTask.Finished;
  end;
  Result := not FDone;
end;

end.
