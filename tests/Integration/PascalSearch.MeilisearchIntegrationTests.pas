unit PascalSearch.MeilisearchIntegrationTests;

{ The Meilisearch adapter against a real Meilisearch (v1.56.2 in Docker,
  tools/engines.sh): what the contract suite can't check because the mock has
  no transport, no TLS and no tasks.

  - TLS through pascal-common-faa's client: the private CA accepted, the
    system store and a wrong host name refused, plain http to the TLS port
    an error and not an empty answer (findings 40-42 of the engine probe,
    measured on fphttpclient; here on PascalCommon.Http).
  - A wrong key, a write to an index never ensured (not created), a refused
    document failing its whole batch, a kind change applied in place, the
    native access.

  - Telemetry (design, section 13) on the real engine: under a span, every
    request is a client span the engine answered without an error (it
    accepts the traceparent), Get's url.full ends with the id, the task polls make no span
    and each wait is one meilisearch.wait_task span with its polls.

  Each test uses its own index (it_*), dropped before and after.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Integration/fpc is
  generated from the master by tools/gen_fpc_mirror.py: edit only the
  master. }

interface

uses
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalCommon.Tracing,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Meilisearch,
  PascalSearch.IntegrationEnv;

type
  // Keeps every span it is given.
  TMeiliItSpanExporter = class(TInterfacedObject, IPcSpanExporter)
  public
    Spans: TPcSpanDataArray;
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
  end;

  [TestFixture]
  TMeilisearchIntegrationTests = class
  private
    FEngine: IMeilisearchEngine;
    function TlsEngine(const AUrl, ACaFile: string): IMeilisearchEngine;
    procedure ExpectUnavailable(const AEngine: IMeilisearchEngine; const AWhat: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Tls_PrivateCa_Accepted;
    [Test] procedure Tls_SystemStore_Refused;
    [Test] procedure Tls_WrongHostName_Refused;
    [Test] procedure Tls_PlainHttpToTlsPort_Unavailable;

    [Test] procedure Auth_WrongKey;
    [Test] procedure Write_IndexNeverEnsured_NotCreated;
    [Test] procedure Write_RefusedDocument_WholeBatch;
    [Test] procedure Write_Pending_ThenDone;
    [Test] procedure Schema_NoTextFields;
    [Test] procedure Schema_KindChange_InPlace;
    [Test] procedure Native_SendAndWaitForTask;
    [Test] procedure Native_TypoTolerance;
    [Test] procedure Native_StopWordsAndRankingRules;
    [Test] procedure ReplaceIndex_SettingsTravel;
    [Test] procedure Telemetry_UnderASpan_ClientSpansAndWaits;
  end;

implementation

const
  IDX = 'it_meili';
  NEVER = 'it_never';
  STAGING = 'it_meili_new';

{ TMeiliItSpanExporter }

function TMeiliItSpanExporter.ExportSpans(const ASpans: TPcSpanDataArray;
  out AError: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ASpans) do
  begin
    SetLength(Spans, Length(Spans) + 1);
    Spans[High(Spans)] := ASpans[I];
  end;
  AError := '';
  Result := True;
end;

// The attribute AKey of AData as text, '' when absent.
function MeiliItAttr(const AData: TPcSpanData; const AKey: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AData.Attributes) do
    if AData.Attributes[I].Key = AKey then
    begin
      if AData.Attributes[I].ValueType = satInt then
        Result := IntToStr(AData.Attributes[I].IntValue)
      else
        Result := AData.Attributes[I].StringValue;
      Exit;
    end;
end;

{ TMeilisearchIntegrationTests }

procedure TMeilisearchIntegrationTests.Setup;
begin
  FEngine := TMeilisearchEngine.New(MeiliConfig);
  FEngine.DropIndex(IDX);
  FEngine.DropIndex(NEVER);
end;

procedure TMeilisearchIntegrationTests.TearDown;
begin
  try
    if FEngine <> nil then
    begin
      FEngine.DropIndex(IDX);
      FEngine.DropIndex(NEVER);
      FEngine.DropIndex(STAGING);
    end;
  except
    // The next Setup drops them again.
  end;
  FEngine := nil;
end;

function TMeilisearchIntegrationTests.TlsEngine(const AUrl, ACaFile: string): IMeilisearchEngine;
var
  LConfig: TMeilisearchConfig;
begin
  LConfig := TMeilisearchConfig.Create(AUrl, MeiliKey);
  LConfig.TimeoutMs := 5000;
  LConfig.Http.Tls.CaFile := ACaFile;
  Result := TMeilisearchEngine.New(LConfig);
end;

procedure TMeilisearchIntegrationTests.ExpectUnavailable(const AEngine: IMeilisearchEngine;
  const AWhat: string);
begin
  try
    AEngine.IndexExists(IDX);
    TAssert.Fail(AWhat + ': must not connect');
  except
    on E: ESearchUnavailable do
      TAssert.AssertEquals(AWhat + ': ' + E.Message, 0, E.HttpStatus);
  end;
end;

procedure TMeilisearchIntegrationTests.Tls_PrivateCa_Accepted;
var
  LEngine: IMeilisearchEngine;
begin
  TAssert.AssertTrue('the CA file (SEARCH_CA_FILE or .ci/it-certs/ca.pem)', CaFile <> '');
  LEngine := TlsEngine(MeiliTlsUrl, CaFile);
  TAssert.AssertFalse(LEngine.IndexExists(IDX));
  TAssert.AssertTrue(Pos('"pkgVersion":"1.56.2"', LEngine.Send('GET', '/version')) > 0);
end;

procedure TMeilisearchIntegrationTests.Tls_SystemStore_Refused;
begin
  ExpectUnavailable(TlsEngine(MeiliTlsUrl, ''), 'a private CA against the system store');
end;

procedure TMeilisearchIntegrationTests.Tls_WrongHostName_Refused;
begin
  ExpectUnavailable(TlsEngine(MeiliTlsWrongUrl, CaFile), 'a name the certificate doesn''t hold');
end;

procedure TMeilisearchIntegrationTests.Tls_PlainHttpToTlsPort_Unavailable;
begin
  ExpectUnavailable(TlsEngine(MeiliTlsPlainUrl, ''), 'http to the TLS port');
end;

procedure TMeilisearchIntegrationTests.Auth_WrongKey;
begin
  try
    TMeilisearchEngine.New(TMeilisearchConfig.Create(MeiliUrl, 'wrong-key')).IndexExists(IDX);
    TAssert.Fail('A wrong key must raise');
  except
    on E: ESearchAuthError do
      TAssert.AssertEquals('invalid_api_key', E.EngineCode);
  end;
  try
    TMeilisearchEngine.New(TMeilisearchConfig.Create(MeiliUrl)).IndexExists(IDX);
    TAssert.Fail('No key must raise');
  except
    on E: ESearchAuthError do
      TAssert.AssertEquals('missing_authorization_header', E.EngineCode);
  end;
end;

procedure TMeilisearchIntegrationTests.Write_IndexNeverEnsured_NotCreated;
begin
  try
    FEngine.Index(NEVER).Upsert([TSearchDocument.New('1').Str('title', 'x')]);
    TAssert.Fail('A write to an index never ensured must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos(NEVER, E.Message) > 0);
  end;
  TAssert.AssertFalse('Meilisearch would have created it', FEngine.IndexExists(NEVER));
end;

procedure TMeilisearchIntegrationTests.Write_RefusedDocument_WholeBatch;
var
  LIndex: ISearchIndex;
begin
  // _geo is reserved: once filterable, a string there fails the task.
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title').Keyword('_geo', [sfFilter]));
  try
    LIndex.Upsert([TSearchDocument.New('good').Str('title', 'ok'),
      TSearchDocument.New('bad').Str('_geo', 'nowhere')]).WaitFor(30000);
    TAssert.Fail('A refused document must fail the write');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertTrue(E.WholeBatch);
      TAssert.AssertEquals(2, Length(E.Failures));
      TAssert.AssertEquals('good', E.Failures[0].Id);
      TAssert.AssertTrue(E.Failures[0].Code, Pos('geo', E.Failures[0].Code) > 0);
    end;
  end;
  TAssert.AssertTrue('all or nothing (finding 2)', LIndex.Get('good') = nil);
end;

procedure TMeilisearchIntegrationTests.Write_Pending_ThenDone;
var
  LIndex: ISearchIndex;
  W: ISearchWrite;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  W := LIndex.Upsert([TSearchDocument.New('1').Str('title', 'pendente')]);
  W.Pending;   // either: it may already be done
  W.WaitFor(30000);
  TAssert.AssertFalse(W.Pending);
  TAssert.AssertEquals('1', LIndex.Get('1').Id);
end;

procedure TMeilisearchIntegrationTests.Schema_NoTextFields;
var
  LIndex: ISearchIndex;
begin
  // Like the mock: without Text fields the words match nothing, and an
  // empty text still matches every document.
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Keyword('code', [sfFilter]));
  LIndex.Upsert([TSearchDocument.New('1').Str('code', 'abc')]).WaitFor(30000);
  TAssert.AssertEquals(Int64(0), LIndex.Search('abc').Execute.Total);
  TAssert.AssertEquals(Int64(1), LIndex.Search('').Execute.Total);
  TAssert.AssertEquals(Int64(1), LIndex.Search('').Where(F.Eq('code', 'ABC')).Execute.Total);
end;

procedure TMeilisearchIntegrationTests.Schema_KindChange_InPlace;
var
  LIndex: ISearchIndex;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Num('price', [sfFilter]));
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Keyword('price', [sfFilter]));
  LIndex.Upsert([TSearchDocument.New('1').Str('price', 'cheap')]).WaitFor(30000);
  TAssert.AssertEquals(Int64(1), LIndex.Search('').Where(F.Eq('price', 'cheap')).Execute.Total);
end;

procedure TMeilisearchIntegrationTests.Native_SendAndWaitForTask;
var
  LJson: TJsonValue;
  LUid: Int64;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  LJson := ParseJson(FEngine.Send('PUT', '/indexes/' + IDX + '/settings/synonyms',
    '{"leite":["milk"]}'));
  try
    TAssert.AssertTrue(LJson.Find('taskUid').TryAsInt64(LUid));
  finally
    LJson.Free;
  end;
  FEngine.WaitForTask(LUid, 30000);
  TAssert.AssertTrue(Pos('milk', FEngine.Send('GET', '/indexes/' + IDX + '/settings/synonyms')) > 0);
  try
    FEngine.Send('GET', '/indexes/' + NEVER + '/settings');
    TAssert.Fail('A missing index must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertEquals(404, E.HttpStatus);
  end;
end;

function NoTypos: TMeilisearchTypoTolerance;
begin
  Result := TMeilisearchTypoTolerance.Standard;
  Result.Enabled := False;
end;

procedure TMeilisearchIntegrationTests.Native_TypoTolerance;
var
  LIndex: ISearchIndex;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  LIndex.Upsert([TSearchDocument.New('1').Str('title', 'queijo')]).WaitFor;
  TAssert.AssertEquals('one typo from 5 letters (finding 16)', Int64(1), LIndex.Search('queiju').Execute.Total);
  FEngine.SetTypoTolerance(IDX, NoTypos);
  TAssert.AssertEquals('applied on return', Int64(0), LIndex.Search('queiju').Execute.Total);
  TAssert.AssertTrue(Pos('"enabled":false', FEngine.Send('GET', '/indexes/' + IDX + '/settings/typo-tolerance')) > 0);
end;

procedure TMeilisearchIntegrationTests.Native_StopWordsAndRankingRules;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title').Num('price', [sfSort]));
  FEngine.SetStopWords(IDX, ['de', 'com']);
  TAssert.AssertEquals('["com","de"]', FEngine.Send('GET', '/indexes/' + IDX + '/settings/stop-words'));
  FEngine.SetRankingRules(IDX, ['words', 'typo', 'proximity', 'attribute', 'sort', 'exactness', 'price:asc']);
  TAssert.AssertTrue(Pos('price:asc', FEngine.Send('GET', '/indexes/' + IDX + '/settings/ranking-rules')) > 0);
  try
    FEngine.SetRankingRules(IDX, ['nope']);
    TAssert.Fail('An unknown rule must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertEquals('invalid_settings_ranking_rules', E.EngineCode);
  end;
  try
    FEngine.SetStopWords(NEVER, []);
    TAssert.Fail('A missing index must raise');
  except
    on ESearchIndexNotFound do
      TAssert.AssertFalse('not created by the settings call', FEngine.IndexExists(NEVER));
  end;
end;

procedure TMeilisearchIntegrationTests.ReplaceIndex_SettingsTravel;
var
  LIndex: ISearchIndex;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  LIndex.Upsert([TSearchDocument.New('old').Str('title', 'queijo')]).WaitFor;
  FEngine.DropIndex(STAGING);
  FEngine.EnsureIndex(TSearchSchema.New(STAGING).Text('title'))
    .Upsert([TSearchDocument.New('new').Str('title', 'queijo')]).WaitFor;
  FEngine.SetTypoTolerance(STAGING, NoTypos);
  FEngine.ReplaceIndex(IDX, STAGING);
  TAssert.AssertEquals('new', LIndex.Search('queijo').Execute.Hit(0).Id);
  TAssert.AssertEquals('the source''s settings came along', Int64(0), LIndex.Search('queiju').Execute.Total);
  TAssert.AssertFalse(FEngine.IndexExists(STAGING));
end;

procedure TMeilisearchIntegrationTests.Telemetry_UnderASpan_ClientSpansAndWaits;
var
  LExporterObj: TMeiliItSpanExporter;
  LExporter: IPcSpanExporter;
  LParent: IPcSpan;
  LIndex: ISearchIndex;
  LData: TPcSpanData;
  LClients, LWaits, I: Integer;
  LGetSeen: Boolean;
begin
  LExporterObj := TMeiliItSpanExporter.Create;
  LExporter := LExporterObj;
  TPcTracing.Start(TPcTracingOptions.Default('search-it', '1.0.0'), LExporter, False);
  try
    LParent := TPcTracing.StartSpan('handler', skServer);
    try
      LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
      LIndex.Upsert([TSearchDocument.New('7').Str('title', 'Café')]).WaitFor(30000);
      TAssert.AssertEquals(Int64(1), LIndex.Search('cafe').Execute.Total);
      TAssert.AssertEquals('7', LIndex.Get('7').Id);
    finally
      LParent.Finish;
    end;
    TPcTracing.FlushNow;
    LClients := 0;
    LWaits := 0;
    LGetSeen := False;
    for I := 0 to High(LExporterObj.Spans) do
    begin
      LData := LExporterObj.Spans[I];
      if LData.SpanId = LParent.SpanId then
        Continue;
      TAssert.AssertEquals(LParent.TraceId, LData.TraceId);
      TAssert.AssertEquals(LParent.SpanId, LData.ParentSpanId);
      if LData.Kind = skClient then
      begin
        Inc(LClients);
        // A 404 is EnsureIndex's lookup of an index not there yet.
        if MeiliItAttr(LData, 'http.response.status_code') <> '404' then
          TAssert.AssertTrue(LData.Name + ' ' + MeiliItAttr(LData, 'url.full') + ': no error',
            LData.Status = ssUnset);
        TAssert.AssertEquals('a poll makes no span', 0, Pos('/tasks/', MeiliItAttr(LData, 'url.full')));
        if MeiliItAttr(LData, 'url.full') = MeiliUrl + '/indexes/' + IDX + '/documents/7' then
          LGetSeen := True;
      end
      else
      begin
        Inc(LWaits);
        TAssert.AssertEquals(MEILISEARCH_WAIT_SPAN, LData.Name);
        TAssert.AssertEquals('succeeded', MeiliItAttr(LData, 'meilisearch.task.status'));
        TAssert.AssertTrue('at least one poll', StrToInt(MeiliItAttr(LData, 'meilisearch.task.polls')) >= 1);
      end;
    end;
    // EnsureIndex: the lookup, the create, the settings; the upsert: the
    // check and the POST; the search; Get. Waits: create, settings, upsert.
    TAssert.AssertEquals(7, LClients);
    TAssert.AssertEquals(3, LWaits);
    TAssert.AssertTrue('Get''s url.full holds the id', LGetSeen);
    LParent := nil;
  finally
    TPcTracing.Shutdown;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMeilisearchIntegrationTests);

end.
