unit PascalSearch.MeilisearchTests;

(* The Meilisearch adapter without a server: every request goes to
   pascal-common-faa's TPcFakeHttpTransport, which answers from a queue and
   keeps what was sent. The tests check what the adapter sends (method, URL,
   key, body) and how it reads each answer (2xx, Meilisearch's errors, a lost
   connection), plus the filter text with the probe's hostile values
   (docs/design.md, S13 and S24). Task polling runs on a fake clock: TSleep
   advances TTicker, so nothing sleeps.

   The telemetry tests (design, section 13) start TPcTracing without its
   export thread and read the spans from a fake exporter after FlushNow;
   http.client.request.duration is the process-wide histogram, read before
   and after.

   What Meilisearch itself does with these requests is the integration
   suite's job (tests/Integration).

   DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
   PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
   the master by tools/gen_fpc_mirror.py: edit only the master. *)

interface

uses
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalCommon.SystemContext,
  PascalCommon.TraceContext,
  PascalCommon.Tracing,
  PascalCommon.Metrics,
  PascalCommon.Http,
  PascalCommon.Http.Fake,
  PascalCommon.Http.Telemetry,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Meilisearch;

type
  // ISleep and ITicker in one: a sleep moves the clock.
  TFakeTime = class(TInterfacedObject, ISleep, ITicker)
  private
    FNow: UInt64;
    FSleeps: string;
  public
    procedure Sleep(milliseconds: Cardinal);
    function NowMs: UInt64;
    property Sleeps: string read FSleeps;
  end;

  // Keeps every span it is given.
  TMeiliSpanExporter = class(TInterfacedObject, IPcSpanExporter)
  public
    Spans: TPcSpanDataArray;
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
  end;

  [TestFixture]
  TMeilisearchTests = class
  private
    FFake: TPcFakeHttpTransport;
    FTransport: IPcHttpTransport;
    FTime: TFakeTime;
    FTimeRef: ISleep;
    FEngine: IMeilisearchEngine;
    procedure Ok(const ABody: string);
    procedure Task(AUid: Integer; const AStatus: string; const AError: string = 'null');
    procedure Accepted(AUid: Integer);
    procedure IndexFound;
    procedure IndexMissing;
    function Req(AIndex: Integer): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Filter_StringsQuotedAndEscaped;
    [Test] procedure Filter_EveryOperator;
    [Test] procedure Filter_NumbersPlainInstantsInMs;

    [Test] procedure Config_BadUrl_ArgumentError;
    [Test] procedure EnsureIndex_New_CreatesAndSendsSettings;
    [Test] procedure EnsureIndex_Existing_SettingsOnly;
    [Test] procedure EnsureIndex_OtherPrimaryKey_SchemaError;
    [Test] procedure EnsureIndex_CreatedMeanwhile_NoError;

    [Test] procedure Upsert_SendsDocuments_WaitForPolls;
    [Test] procedure Upsert_TaskFailed_WholeBatch;
    [Test] procedure Upsert_IndexMissing_NothingSent;
    [Test] procedure Upsert_Empty_NoTask;
    [Test] procedure Write_NoAnswer_Unavailable;
    [Test] procedure WaitFor_Timeout;
    [Test] procedure Pending_AsksOnceDone;
    [Test] procedure Delete_SendsIds;
    [Test] procedure DeleteWhere_Failed_RequestError;

    [Test] procedure Search_RequestBody;
    [Test] procedure Search_RawReplacesParameter;
    [Test] procedure Search_ReadsAnswer;
    [Test] procedure Search_PastMaxHits_ReadsSettingsOnce;
    [Test] procedure Errors_Mapped;

    [Test] procedure Get_FoundMissingAndNoIndex;
    [Test] procedure GetMany_OrderAsked;
    [Test] procedure DropIndex_Missing_NoError;
    [Test] procedure Send_NativeAccess;

    [Test] procedure ReplaceIndex_ExistingTarget_SwapsAndDrops;
    [Test] procedure ReplaceIndex_MissingTarget_Renames;
    [Test] procedure ReplaceIndex_MissingSource_NothingSent;
    [Test] procedure ListIds_Pages;
    [Test] procedure SynonymsJson_Merged;
    [Test] procedure SetSynonyms_PutsSettingAndWaits;
    [Test] procedure Search_Highlight;
    [Test] procedure NativeSettings_Sent;
    [Test] procedure MaxHits_CacheExpires;
    [Test] procedure Telemetry_UnderASpan_ClientSpansAndOneWaitSpan;
    [Test] procedure Telemetry_NoCurrentSpan_NoSpanOnlyTheMetric;
    [Test] procedure Telemetry_FailedTaskOrTimeout_WaitSpanIsAnError;
  end;

implementation

const
  BASE = 'http://meili:7700';
  NOT_FOUND = '{"message":"Index `products` not found.","code":"index_not_found",' +
    '"type":"invalid_request","link":"https://docs.meilisearch.com/errors#index_not_found"}';

{ TFakeTime }

procedure TFakeTime.Sleep(milliseconds: Cardinal);
begin
  Inc(FNow, milliseconds);
  if FSleeps <> '' then
    FSleeps := FSleeps + ',';
  FSleeps := FSleeps + IntToStr(milliseconds);
end;

function TFakeTime.NowMs: UInt64;
begin
  Result := FNow;
end;

{ TMeiliSpanExporter }

function TMeiliSpanExporter.ExportSpans(const ASpans: TPcSpanDataArray;
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
function MeiliAttr(const AData: TPcSpanData; const AKey: string): string;
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

// The points of http.client.request.duration for AMethod to meili:7700
// answered 2xx.
function MeiliDurationCount(const AMethod: string): UInt64;
var
  LMetrics: TPcMetricList;
  LPoints: TPcMetricPoints;
  I, M: Integer;
begin
  Result := 0;
  LMetrics := PcMetrics.Metrics;
  for M := 0 to High(LMetrics) do
    if LMetrics[M].Name = PC_HTTP_CLIENT_DURATION_METRIC then
    begin
      LPoints := LMetrics[M].Snapshot;
      for I := 0 to High(LPoints) do
        if (LPoints[I].LabelValues[0] = AMethod) and (LPoints[I].LabelValues[1] = 'meili') and
           (LPoints[I].LabelValues[2] = '7700') and (Copy(LPoints[I].LabelValues[4], 1, 1) = '2') then
          Inc(Result, LPoints[I].Count);
    end;
end;

{ TMeilisearchTests }

procedure TMeilisearchTests.Setup;
begin
  FFake := TPcFakeHttpTransport.Create;
  FTransport := FFake;
  FTime := TFakeTime.Create;
  FTimeRef := FTime;
  TSleep.SetSleep(FTime);
  TTicker.SetTicker(FTime);
  FEngine := TMeilisearchEngine.New(TMeilisearchConfig.Create(BASE + '/', 'secret'), FTransport);
end;

procedure TMeilisearchTests.TearDown;
begin
  FEngine := nil;
  TSleep.Reset;
  TTicker.Reset;
  FTimeRef := nil;
  FTime := nil;
  FTransport := nil;
  FFake := nil;
end;

procedure TMeilisearchTests.Ok(const ABody: string);
begin
  FFake.Answer(200, ABody);
end;

procedure TMeilisearchTests.Task(AUid: Integer; const AStatus, AError: string);
begin
  FFake.Answer(200, Format('{"uid":%d,"status":"%s","error":%s}', [AUid, AStatus, AError]));
end;

procedure TMeilisearchTests.Accepted(AUid: Integer);
begin
  FFake.Answer(202, Format('{"taskUid":%d,"status":"enqueued"}', [AUid]));
end;

procedure TMeilisearchTests.IndexFound;
begin
  Ok('{"uid":"products","primaryKey":"id"}');
end;

procedure TMeilisearchTests.IndexMissing;
begin
  FFake.Answer(404, NOT_FOUND);
end;

// "METHOD url" of request AIndex, the base cut off.
function TMeilisearchTests.Req(AIndex: Integer): string;
var
  R: TPcHttpRequest;
begin
  R := FFake.Request(AIndex);
  Result := R.Method + ' ' + StringReplace(R.Url, BASE, '', []);
end;

procedure TMeilisearchTests.Filter_StringsQuotedAndEscaped;
begin
  TAssert.AssertEquals('category = "bebida"', MeilisearchFilterText(F.Eq('category', 'bebida')));
  TAssert.AssertEquals('category = "Bar \"Zé\""', MeilisearchFilterText(F.Eq('category', 'Bar "Zé"')));
  TAssert.AssertEquals('category = "C:\\doces\\"', MeilisearchFilterText(F.Eq('category', 'C:\doces\')));
  TAssert.AssertEquals('category = "x\" OR price > 0 OR category = \"y"',
    MeilisearchFilterText(F.Eq('category', 'x" OR price > 0 OR category = "y')));
  TAssert.AssertEquals('category = "x''y`z, w"', MeilisearchFilterText(F.Eq('category', 'x''y`z, w')));
  TAssert.AssertEquals('"\\"', MeilisearchQuote('\'));
end;

procedure TMeilisearchTests.Filter_EveryOperator;
begin
  TAssert.AssertEquals('category != "bebida"', MeilisearchFilterText(F.NotEq('category', 'bebida')));
  TAssert.AssertEquals('id IN ["1", "7"]', MeilisearchFilterText(F.AnyOf('id', ['1', '7'])));
  TAssert.AssertEquals('tags NOT IN ["a", "b\""]', MeilisearchFilterText(F.NoneOf('tags', ['a', 'b"'])));
  TAssert.AssertEquals('stock > 0', MeilisearchFilterText(F.Gt('stock', Int64(0))));
  TAssert.AssertEquals('stock >= 1', MeilisearchFilterText(F.Ge('stock', Int64(1))));
  TAssert.AssertEquals('stock < 2', MeilisearchFilterText(F.Lt('stock', Int64(2))));
  TAssert.AssertEquals('stock <= 3', MeilisearchFilterText(F.Le('stock', Int64(3))));
  TAssert.AssertEquals('price 5 TO 8.5', MeilisearchFilterText(F.Between('price', 5.0, 8.5)));
  TAssert.AssertEquals('(available = true) AND ((stock > 0) OR (available = false))',
    MeilisearchFilterText(F.All([F.Eq('available', True),
      F.Any([F.Gt('stock', Int64(0)), F.Eq('available', False)])])));
end;

procedure TMeilisearchTests.Filter_NumbersPlainInstantsInMs;
begin
  TAssert.AssertEquals('price > 1000000000000000000000', MeilisearchFilterText(F.Gt('price', 1e21)));
  TAssert.AssertEquals('price < 0.00000015', MeilisearchFilterText(F.Lt('price', 1.5e-7)));
  TAssert.AssertEquals('created_at >= 1767225600000',
    MeilisearchFilterText(F.Ge('created_at', F.At(EncodeDate(2026, 1, 1)))));
end;

procedure TMeilisearchTests.Config_BadUrl_ArgumentError;
const
  BAD: array[0..3] of string = ('', 'ftp://meili', 'http://meili:7700/x', 'http://me ili');
var
  I: Integer;
begin
  for I := 0 to High(BAD) do
    try
      TMeilisearchEngine.New(TMeilisearchConfig.Create(BAD[I]), FTransport);
      TAssert.Fail('Accepted the URL "' + BAD[I] + '"');
    except
      on E: ESearchArgumentError do
        TAssert.AssertTrue(E.Message, Pos('URL', E.Message) > 0);
    end;
end;

procedure TMeilisearchTests.EnsureIndex_New_CreatesAndSendsSettings;
var
  LIndex: ISearchIndex;
begin
  IndexMissing;
  Accepted(1);
  Task(1, 'succeeded');
  Accepted(2);
  Task(2, 'processing');
  Task(2, 'succeeded');
  LIndex := FEngine.EnsureIndex(TSearchSchema.New('products')
    .Text('title').Text('body')
    .Keyword('category', [sfFilter, sfFacet])
    .Keywords('tags', [sfFacet])
    .Num('price', [sfFilter, sfSort])
    .Instant('created_at', [sfSort])
    .Stored('note')
    .WithMaxHits(5000));
  TAssert.AssertEquals('products', LIndex.Name);
  TAssert.AssertEquals(6, FFake.RequestCount);
  TAssert.AssertEquals('GET /indexes/products', Req(0));
  TAssert.AssertEquals('Bearer secret', FFake.Request(0).Header('Authorization'));
  TAssert.AssertEquals('POST /indexes', Req(1));
  TAssert.AssertEquals('{"uid":"products","primaryKey":"id"}', FFake.Request(1).Body);
  TAssert.AssertEquals('application/json', FFake.Request(1).Header('Content-Type'));
  TAssert.AssertEquals('GET /tasks/1', Req(2));
  TAssert.AssertEquals('PATCH /indexes/products/settings', Req(3));
  TAssert.AssertEquals('{"searchableAttributes":["title","body"],' +
    '"filterableAttributes":["id","category","tags","price"],' +
    '"sortableAttributes":["price","created_at"],' +
    '"pagination":{"maxTotalHits":5000},' +
    '"faceting":{"sortFacetValuesBy":{"*":"count"}}}', FFake.Request(3).Body);
  TAssert.AssertEquals('GET /tasks/2', Req(5));
  TAssert.AssertEquals('one poll after the first read', '5', FTime.Sleeps);
end;

procedure TMeilisearchTests.EnsureIndex_Existing_SettingsOnly;
begin
  IndexFound;
  Accepted(9);
  Task(9, 'succeeded');
  FEngine.EnsureIndex(TSearchSchema.New('products').Text('title'));
  TAssert.AssertEquals(3, FFake.RequestCount);
  TAssert.AssertEquals('PATCH /indexes/products/settings', Req(1));
end;

procedure TMeilisearchTests.EnsureIndex_OtherPrimaryKey_SchemaError;
begin
  Ok('{"uid":"products","primaryKey":"code"}');
  try
    FEngine.EnsureIndex(TSearchSchema.New('products').Text('title'));
    TAssert.Fail('An index keyed by another field must raise');
  except
    on E: ESearchSchemaError do
      TAssert.AssertTrue(E.Message, Pos('"code"', E.Message) > 0);
  end;
  TAssert.AssertEquals(1, FFake.RequestCount);
end;

procedure TMeilisearchTests.EnsureIndex_CreatedMeanwhile_NoError;
begin
  IndexMissing;
  Accepted(1);
  Task(1, 'failed', '{"message":"Index `products` already exists.","code":"index_already_exists",' +
    '"type":"invalid_request"}');
  Accepted(2);
  Task(2, 'succeeded');
  FEngine.EnsureIndex(TSearchSchema.New('products').Text('title'));
  TAssert.AssertEquals(5, FFake.RequestCount);
end;

procedure TMeilisearchTests.Upsert_SendsDocuments_WaitForPolls;
var
  W: ISearchWrite;
begin
  IndexFound;
  Accepted(7);
  W := FEngine.Index('products').Upsert([
    TSearchDocument.New('1').Str('title', 'Café').Num('price', 7.5),
    TSearchDocument.New('2').Bool('available', False)]);
  TAssert.AssertEquals('GET /indexes/products', Req(0));
  TAssert.AssertEquals('POST /indexes/products/documents?primaryKey=id', Req(1));
  TAssert.AssertEquals('[{"id":"1","title":"Café","price":7.5},{"id":"2","available":false}]',
    FFake.Request(1).Body);
  Task(7, 'enqueued');
  Task(7, 'processing');
  Task(7, 'processing');
  Task(7, 'succeeded');
  W.WaitFor;
  TAssert.AssertEquals('5,10,20', FTime.Sleeps);
  TAssert.AssertEquals('GET /tasks/7', Req(5));
  // Done: a second WaitFor asks nothing.
  W.WaitFor;
  TAssert.AssertEquals(6, FFake.RequestCount);
end;

procedure TMeilisearchTests.Upsert_TaskFailed_WholeBatch;
var
  W: ISearchWrite;
  I: Integer;
begin
  IndexFound;
  Accepted(3);
  W := FEngine.Index('products').Upsert([TSearchDocument.New('a'), TSearchDocument.New('b')]);
  Task(3, 'failed', '{"message":"Document has a bad field.","code":"invalid_document_fields",' +
    '"type":"invalid_request"}');
  for I := 1 to 2 do
    try
      W.WaitFor;
      TAssert.Fail('A failed task must raise');
    except
      on E: ESearchWriteFailed do
      begin
        TAssert.AssertTrue(E.WholeBatch);
        TAssert.AssertEquals(2, Length(E.Failures));
        TAssert.AssertEquals('b', E.Failures[1].Id);
        TAssert.AssertEquals('invalid_document_fields', E.Failures[1].Code);
        TAssert.AssertEquals('Document has a bad field.', E.Failures[0].Message);
      end;
    end;
  TAssert.AssertEquals('the failure is kept, not asked again', 3, FFake.RequestCount);
end;

procedure TMeilisearchTests.Upsert_IndexMissing_NothingSent;
begin
  IndexMissing;
  try
    FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
    TAssert.Fail('A write to a missing index must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertEquals('index_not_found', E.EngineCode);
  end;
  TAssert.AssertEquals('no write sent: Meilisearch would create the index', 1, FFake.RequestCount);
end;

procedure TMeilisearchTests.Upsert_Empty_NoTask;
var
  W: ISearchWrite;
begin
  IndexFound;
  W := FEngine.Index('products').Upsert([]);
  TAssert.AssertFalse(W.Pending);
  W.WaitFor;
  TAssert.AssertEquals(1, FFake.RequestCount);
end;

procedure TMeilisearchTests.Write_NoAnswer_Unavailable;
begin
  IndexFound;
  FFake.Fail('POST http://meili:7700/indexes/products/documents: no answer (connection reset)');
  try
    FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
    TAssert.Fail('A write without an answer must raise');
  except
    on E: ESearchUnavailable do
      TAssert.AssertTrue(E.Message, Pos('connection reset', E.Message) > 0);
  end;
  TAssert.AssertEquals('sent once', 2, FFake.RequestCount);
end;

procedure TMeilisearchTests.WaitFor_Timeout;
var
  W: ISearchWrite;
  I: Integer;
begin
  IndexFound;
  Accepted(4);
  W := FEngine.Index('products').Delete(['1']);
  for I := 1 to 6 do
    Task(4, 'processing');
  try
    W.WaitFor(100);
    TAssert.Fail('A task still running past the limit must raise');
  except
    on E: ESearchTimeout do
      TAssert.AssertTrue(E.Message, Pos('task 4', E.Message) > 0);
  end;
  TAssert.AssertEquals('5,10,20,40,80', FTime.Sleeps);
  TAssert.AssertEquals(0, FFake.Pending);
end;

procedure TMeilisearchTests.Pending_AsksOnceDone;
var
  W: ISearchWrite;
begin
  IndexFound;
  Accepted(5);
  W := FEngine.Index('products').Delete(['1']);
  Task(5, 'enqueued');
  TAssert.AssertTrue(W.Pending);
  Task(5, 'succeeded');
  TAssert.AssertFalse(W.Pending);
  TAssert.AssertFalse(W.Pending);
  W.WaitFor;
  TAssert.AssertEquals(4, FFake.RequestCount);
end;

procedure TMeilisearchTests.Delete_SendsIds;
begin
  IndexFound;
  Accepted(6);
  FEngine.Index('products').Delete(['1', 'a-b_c']);
  TAssert.AssertEquals('POST /indexes/products/documents/delete-batch', Req(1));
  TAssert.AssertEquals('["1","a-b_c"]', FFake.Request(1).Body);
  try
    FEngine.Index('products').Delete(['a b']);
    TAssert.Fail('An invalid id must raise before sending');
  except
    on ESearchArgumentError do
      TAssert.AssertEquals(2, FFake.RequestCount);
  end;
end;

procedure TMeilisearchTests.DeleteWhere_Failed_RequestError;
var
  W: ISearchWrite;
begin
  IndexFound;
  Accepted(8);
  W := FEngine.Index('products').DeleteWhere(F.Eq('body', 'x'));
  TAssert.AssertEquals('POST /indexes/products/documents/delete', Req(1));
  TAssert.AssertEquals('{"filter":"body = \"x\""}', FFake.Request(1).Body);
  Task(8, 'failed', '{"message":"Attribute `body` is not filterable.","code":"invalid_document_filter",' +
    '"type":"invalid_request"}');
  try
    W.WaitFor;
    TAssert.Fail('A failed delete by filter must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertEquals('invalid_document_filter', E.EngineCode);
  end;
end;

procedure TMeilisearchTests.Search_RequestBody;
begin
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('-café "preto"')
    .Where(F.Eq('category', 'bebida'))
    .OrderBy('price', soDesc).ThenBy('created_at')
    .Facets(['category'])
    .Fields(['title'])
    .Execute;
  TAssert.AssertEquals('POST /indexes/products/search', Req(0));
  TAssert.AssertEquals('{"q":"café preto","matchingStrategy":"all","filter":"category = \"bebida\"",' +
    '"sort":["price:desc","created_at:asc"],"page":1,"hitsPerPage":20,"facets":["category"],' +
    '"attributesToRetrieve":["title","id"]}', FFake.Request(0).Body);
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('-café').TextMode(tmEngine).Words(swRelaxed).Page(1, 0).Execute;
  TAssert.AssertEquals('{"q":"-café","matchingStrategy":"last","page":1,"hitsPerPage":0}',
    FFake.Request(1).Body);
end;

procedure TMeilisearchTests.Search_RawReplacesParameter;
begin
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('x')
    .Raw('matchingStrategy', '"frequency"')
    .Raw('showRankingScore', 'true')
    .Execute;
  TAssert.AssertEquals('{"q":"x","page":1,"hitsPerPage":20,"matchingStrategy":"frequency",' +
    '"showRankingScore":true}', FFake.Request(0).Body);
end;

procedure TMeilisearchTests.Search_ReadsAnswer;
const
  ANSWER = '{"hits":[{"id":"3","title":"Café preto"},{"id":"1","title":"Café com leite"}],' +
    '"query":"café","processingTimeMs":1,"hitsPerPage":2,"page":1,"totalPages":2,"totalHits":3,' +
    '"facetDistribution":{"category":{"bebida":2,"Bar \"Zé\"":1,"C:\\doces\\":1,"agua":2}}}';
var
  R: ISearchResult;
  LFacet: TSearchFacet;
begin
  Ok(ANSWER);
  R := FEngine.Index('products').Search('café').Page(1, 2).Facets(['category', 'tags']).Execute;
  TAssert.AssertEquals(Int64(3), R.Total);
  TAssert.AssertEquals(2, R.Count);
  TAssert.AssertEquals('3', R.Hit(0).Id);
  TAssert.AssertEquals('Café com leite', R.Hit(1).Document.Find('title').AsString);
  TAssert.AssertEquals(1, R.Page);
  TAssert.AssertEquals(2, R.PageSize);
  TAssert.AssertEquals(ANSWER, R.RawJson);
  TAssert.AssertEquals(2, R.FacetCount);
  TAssert.AssertTrue(R.FindFacet('category', LFacet));
  TAssert.AssertEquals('count, then value', 'agua', LFacet.Values[0].Value);
  TAssert.AssertEquals('bebida', LFacet.Values[1].Value);
  TAssert.AssertEquals('Bar "Zé"', LFacet.Values[2].Value);
  TAssert.AssertEquals('C:\doces\', LFacet.Values[3].Value);
  TAssert.AssertEquals(1, LFacet.Values[3].Count);
  TAssert.AssertTrue(R.FindFacet('tags', LFacet));
  TAssert.AssertEquals('a facet without values is still there', 0, Length(LFacet.Values));
end;

procedure TMeilisearchTests.Search_PastMaxHits_ReadsSettingsOnce;
begin
  Ok('{"maxTotalHits":20}');
  try
    FEngine.Index('products').Search('').Page(3, 10).Execute;
    TAssert.Fail('A page past MaxHits must raise');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('MaxHits (20)', E.Message) > 0);
  end;
  TAssert.AssertEquals('GET /indexes/products/settings/pagination', Req(0));
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('').Page(2, 10).Execute;
  TAssert.AssertEquals(2, FFake.RequestCount);
  TAssert.AssertEquals('POST /indexes/products/search', Req(1));
end;

procedure TMeilisearchTests.Errors_Mapped;

  procedure Check(AStatus: Integer; const ABody: string; AClass: ExceptClass;
    const ACode: string);
  begin
    FFake.Answer(AStatus, ABody);
    try
      FEngine.Index('products').Search('x').Execute;
      TAssert.Fail(Format('HTTP %d must raise', [AStatus]));
    except
      on E: ESearchError do
      begin
        TAssert.AssertEquals(Format('HTTP %d: %s', [AStatus, E.Message]), AClass.ClassName, E.ClassName);
        TAssert.AssertEquals(AStatus, E.HttpStatus);
        TAssert.AssertEquals(ACode, E.EngineCode);
      end;
    end;
  end;

begin
  Check(401, '{"message":"The Authorization header is missing.","code":"missing_authorization_header",' +
    '"type":"auth"}', ESearchAuthError, 'missing_authorization_header');
  Check(403, '{"message":"The provided API key is invalid.","code":"invalid_api_key","type":"auth"}',
    ESearchAuthError, 'invalid_api_key');
  Check(404, NOT_FOUND, ESearchIndexNotFound, 'index_not_found');
  Check(400, '{"message":"Attribute `body` is not filterable.","code":"invalid_search_filter",' +
    '"type":"invalid_request"}', ESearchRequestError, 'invalid_search_filter');
  Check(500, '{"message":"internal","code":"internal","type":"internal"}', ESearchUnavailable, 'internal');
  Check(502, '<html>Bad Gateway</html>', ESearchUnavailable, '');
  FFake.Fail('refused');
  try
    FEngine.Index('products').Search('x').Execute;
    TAssert.Fail('No answer must raise');
  except
    on E: ESearchUnavailable do
      TAssert.AssertEquals(0, E.HttpStatus);
  end;
end;

procedure TMeilisearchTests.Get_FoundMissingAndNoIndex;
var
  H: ISearchHit;
begin
  Ok('{"id":"1","title":"Café","price":7.5}');
  H := FEngine.Index('products').Get('1');
  TAssert.AssertEquals('GET /indexes/products/documents/1', Req(0));
  TAssert.AssertEquals('1', H.Id);
  TAssert.AssertEquals(7.5, H.Document.Find('price').AsDouble, 0);
  FFake.Answer(404, '{"message":"Document `2` not found.","code":"document_not_found",' +
    '"type":"invalid_request"}');
  TAssert.AssertTrue(FEngine.Index('products').Get('2') = nil);
  IndexMissing;
  try
    FEngine.Index('products').Get('3');
    TAssert.Fail('Get on a missing index must raise');
  except
    on ESearchIndexNotFound do
      TAssert.AssertTrue(True);
  end;
end;

procedure TMeilisearchTests.GetMany_OrderAsked;
var
  H: ISearchHits;
begin
  Ok('{"results":[{"id":"1","title":"a"},{"id":"3","title":"c"}],"offset":0,"limit":3,"total":2}');
  H := FEngine.Index('products').GetMany(['3', 'nope', '1', '3']);
  TAssert.AssertEquals('POST /indexes/products/documents/fetch', Req(0));
  TAssert.AssertEquals('{"ids":["3","nope","1"],"limit":3}', FFake.Request(0).Body);
  TAssert.AssertEquals(3, H.Count);
  TAssert.AssertEquals('3', H.Hit(0).Id);
  TAssert.AssertEquals('1', H.Hit(1).Id);
  TAssert.AssertEquals('c', H.Hit(2).Document.Find('title').AsString);
end;

procedure TMeilisearchTests.DropIndex_Missing_NoError;
begin
  Accepted(11);
  Task(11, 'failed', NOT_FOUND);
  FEngine.DropIndex('products');
  TAssert.AssertEquals('DELETE /indexes/products', Req(0));
  FFake.Answer(404, NOT_FOUND);
  FEngine.DropIndex('products');
  TAssert.AssertEquals(3, FFake.RequestCount);
end;

procedure TMeilisearchTests.Send_NativeAccess;
begin
  Ok('{"synonyms":{}}');
  TAssert.AssertEquals('{"synonyms":{}}', FEngine.Send('GET', '/indexes/products/settings/synonyms'));
  TAssert.AssertEquals('Bearer secret', FFake.Request(0).Header('Authorization'));
  TAssert.AssertEquals('', FFake.Request(0).Header('Content-Type'));
  FFake.Answer(400, '{"message":"bad","code":"bad_request","type":"invalid_request"}');
  try
    FEngine.Send('PUT', '/indexes/products/settings/synonyms', '[]');
    TAssert.Fail('A 400 must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertEquals('bad', E.EngineMessage);
  end;
  TAssert.AssertEquals('[]', FFake.Request(1).Body);
end;

procedure TMeilisearchTests.ReplaceIndex_ExistingTarget_SwapsAndDrops;
begin
  IndexFound;
  IndexFound;
  Accepted(5);
  Task(5, 'succeeded');
  Accepted(6);
  Task(6, 'succeeded');
  FEngine.ReplaceIndex('products', 'products_new');
  TAssert.AssertEquals('GET /indexes/products_new', Req(0));
  TAssert.AssertEquals('GET /indexes/products', Req(1));
  TAssert.AssertEquals('POST /swap-indexes', Req(2));
  TAssert.AssertEquals('[{"indexes":["products","products_new"]}]', FFake.Request(2).Body);
  TAssert.AssertEquals('GET /tasks/5', Req(3));
  TAssert.AssertEquals('the source now holds the old documents', 'DELETE /indexes/products_new', Req(4));
  TAssert.AssertEquals('GET /tasks/6', Req(5));
  TAssert.AssertEquals(6, FFake.RequestCount);
end;

procedure TMeilisearchTests.ReplaceIndex_MissingTarget_Renames;
begin
  IndexFound;
  IndexMissing;
  Accepted(5);
  Task(5, 'succeeded');
  FEngine.ReplaceIndex('products', 'products_new');
  TAssert.AssertEquals('POST /swap-indexes', Req(2));
  TAssert.AssertEquals('[{"indexes":["products_new","products"],"rename":true}]', FFake.Request(2).Body);
  TAssert.AssertEquals(4, FFake.RequestCount);
end;

procedure TMeilisearchTests.ReplaceIndex_MissingSource_NothingSent;
begin
  IndexMissing;
  try
    FEngine.ReplaceIndex('products', 'products_new');
    TAssert.Fail('A missing source must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos('products_new', E.Message) > 0);
  end;
  TAssert.AssertEquals(1, FFake.RequestCount);
  try
    FEngine.ReplaceIndex('products', 'products');
    TAssert.Fail('The same name twice must raise');
  except
    on ESearchArgumentError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TMeilisearchTests.ListIds_Pages;
var
  LPage: string;
  LIds: TArray<string>;
  I: Integer;
begin
  LPage := '';
  for I := 0 to 999 do
  begin
    if I > 0 then
      LPage := LPage + ',';
    LPage := LPage + '{"id":"d' + IntToStr(I) + '"}';
  end;
  Ok('{"results":[' + LPage + '],"offset":0,"limit":1000,"total":1002}');
  Ok('{"results":[{"id":"x"},{"id":7}],"offset":1000,"limit":1000,"total":1002}');
  LIds := FEngine.Index('products').ListIds;
  TAssert.AssertEquals(1002, Length(LIds));
  TAssert.AssertEquals('d0', LIds[0]);
  TAssert.AssertEquals('a number id as its text', '7', LIds[1001]);
  TAssert.AssertEquals('POST /indexes/products/documents/fetch', Req(0));
  TAssert.AssertEquals('{"offset":0,"limit":1000,"fields":["id"]}', FFake.Request(0).Body);
  TAssert.AssertEquals('{"offset":1000,"limit":1000,"fields":["id"]}', FFake.Request(1).Body);
  Ok('{"results":[],"offset":0,"limit":1000,"total":0}');
  TAssert.AssertEquals(0, Length(FEngine.Index('products').ListIds(F.Eq('category', 'Bar "Zé"'))));
  TAssert.AssertEquals('{"offset":0,"limit":1000,"fields":["id"],"filter":"category = \"Bar \\\"Zé\\\"\""}',
    FFake.Request(2).Body);
end;

procedure TMeilisearchTests.SynonymsJson_Merged;
begin
  TAssert.AssertEquals('{"tv":["televisão"],"televisão":["tv"]}',
    MeilisearchSynonymsJson([TSearchSynonym.Equivalent(['tv', 'televisão'])]));
  TAssert.AssertEquals('{"a":["b","c"],"b":["a"],"x y":["z"]}',
    MeilisearchSynonymsJson([TSearchSynonym.Equivalent(['a', 'b']), TSearchSynonym.OneWay('a', ['c', 'b']),
      TSearchSynonym.OneWay('x y', ['z'])]));
  TAssert.AssertEquals('{}', MeilisearchSynonymsJson([]));
end;

procedure TMeilisearchTests.SetSynonyms_PutsSettingAndWaits;
begin
  IndexFound;
  Accepted(3);
  Task(3, 'succeeded');
  FEngine.Index('products').SetSynonyms([TSearchSynonym.OneWay('geladeira', ['refrigerador'])]);
  TAssert.AssertEquals('GET /indexes/products', Req(0));
  TAssert.AssertEquals('PUT /indexes/products/settings/synonyms', Req(1));
  TAssert.AssertEquals('{"geladeira":["refrigerador"]}', FFake.Request(1).Body);
  TAssert.AssertEquals('GET /tasks/3', Req(2));
  try
    FEngine.Index('products').SetSynonyms([TSearchSynonym.Equivalent(['so one'])]);
    TAssert.Fail('A group of one word must raise');
  except
    on ESearchArgumentError do
      TAssert.AssertEquals('nothing sent', 3, FFake.RequestCount);
  end;
end;

procedure TMeilisearchTests.Search_Highlight;
var
  R: ISearchResult;
  H: TSearchHighlight;
begin
  Ok('{"hits":[{"id":"1","title":"Café com leite","_formatted":{"id":"1","title":"\u0001Café\u0002 com leite",' +
    '"body":"nada"}}],"totalHits":1,"page":1,"hitsPerPage":20}');
  R := FEngine.Index('products').Search('café').Fields(['title']).Highlight(['title', 'body']).Execute;
  TAssert.AssertEquals('{"q":"café","matchingStrategy":"all","page":1,"hitsPerPage":20,' +
    '"attributesToHighlight":["title","body"],"highlightPreTag":"\u0001","highlightPostTag":"\u0002",' +
    '"attributesToRetrieve":["title","id"]}', FFake.Request(0).Body);
  TAssert.AssertTrue('_formatted is not part of the document', R.Hit(0).Document.Find('_formatted') = nil);
  TAssert.AssertEquals('Café com leite', R.Hit(0).Document.Find('title').AsString);
  TAssert.AssertTrue(R.Hit(0).FindHighlight('title', H));
  TAssert.AssertEquals('<mark>Café</mark> com leite', H.ToHtml);
  TAssert.AssertFalse('a value without marks', R.Hit(0).FindHighlight('body', H));
end;

procedure TMeilisearchTests.NativeSettings_Sent;
var
  LTypos: TMeilisearchTypoTolerance;
begin
  LTypos := TMeilisearchTypoTolerance.Standard;
  TAssert.AssertTrue(LTypos.Enabled);
  LTypos.OneTypo := 4;
  SetLength(LTypos.DisableOnWords, 1);
  LTypos.DisableOnWords[0] := 'tv';
  IndexFound;
  Accepted(1);
  Task(1, 'succeeded');
  FEngine.SetTypoTolerance('products', LTypos);
  TAssert.AssertEquals('PATCH /indexes/products/settings/typo-tolerance', Req(1));
  TAssert.AssertEquals('{"enabled":true,"minWordSizeForTypos":{"oneTypo":4,"twoTypos":9},' +
    '"disableOnWords":["tv"],"disableOnAttributes":[]}', FFake.Request(1).Body);
  IndexFound;
  Accepted(2);
  Task(2, 'succeeded');
  FEngine.SetRankingRules('products', ['words', 'typo', 'price:asc']);
  TAssert.AssertEquals('PUT /indexes/products/settings/ranking-rules', Req(4));
  TAssert.AssertEquals('["words","typo","price:asc"]', FFake.Request(4).Body);
  IndexFound;
  Accepted(3);
  Task(3, 'failed', '{"code":"invalid_settings_stop_words","type":"invalid_request","message":"bad"}');
  try
    FEngine.SetStopWords('products', ['de', 'a']);
    TAssert.Fail('A failed settings task must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertEquals('invalid_settings_stop_words', E.EngineCode);
  end;
  TAssert.AssertEquals('PUT /indexes/products/settings/stop-words', Req(7));
  TAssert.AssertEquals('["de","a"]', FFake.Request(7).Body);
  IndexMissing;
  try
    FEngine.SetStopWords('products', []);
    TAssert.Fail('A missing index must raise (a settings call would create it)');
  except
    on ESearchIndexNotFound do
      TAssert.AssertEquals(10, FFake.RequestCount);
  end;
end;

procedure TMeilisearchTests.MaxHits_CacheExpires;
begin
  Ok('{"maxTotalHits":50}');
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('').Page(2, 10).Execute;
  Ok('{"hits":[],"totalHits":0}');
  FEngine.Index('products').Search('').Page(2, 10).Execute;
  TAssert.AssertEquals('read once', 3, FFake.RequestCount);
  FTime.Sleep(MEILISEARCH_DEFAULT_CACHE_MS);
  Ok('{"maxTotalHits":5}');
  try
    FEngine.Index('products').Search('').Page(2, 10).Execute;
    TAssert.Fail('MaxHits read again (5): page 2 is past it');
  except
    on ESearchArgumentError do
      TAssert.AssertEquals('GET /indexes/products/settings/pagination', Req(3));
  end;
end;

procedure TMeilisearchTests.Telemetry_UnderASpan_ClientSpansAndOneWaitSpan;
var
  LExporterObj: TMeiliSpanExporter;
  LExporter: IPcSpanExporter;
  LParent: IPcSpan;
  LSpans: TPcSpanDataArray;
  LGets, LPosts: UInt64;
  W: ISearchWrite;
  I: Integer;
begin
  LExporterObj := TMeiliSpanExporter.Create;
  LExporter := LExporterObj;
  TPcTracing.Start(TPcTracingOptions.Default('search-tests', '1.0.0'), LExporter, False);
  try
    LGets := MeiliDurationCount('GET');
    LPosts := MeiliDurationCount('POST');
    IndexFound;
    Accepted(7);
    Task(7, 'enqueued');
    Task(7, 'processing');
    Task(7, 'succeeded');
    LParent := TPcTracing.StartSpan('handler', skServer);
    try
      W := FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
      W.WaitFor;
    finally
      LParent.Finish;
    end;
    TPcTracing.FlushNow;
    LSpans := LExporterObj.Spans;
    // GET /indexes/products, POST documents, the wait, the handler.
    TAssert.AssertEquals(4, Length(LSpans));
    TAssert.AssertEquals('GET', LSpans[0].Name);
    TAssert.AssertTrue('a client span', LSpans[0].Kind = skClient);
    TAssert.AssertEquals(LParent.SpanId, LSpans[0].ParentSpanId);
    TAssert.AssertEquals(BASE + '/indexes/products', MeiliAttr(LSpans[0], 'url.full'));
    TAssert.AssertEquals('POST', LSpans[1].Name);
    TAssert.AssertEquals(LParent.TraceId, LSpans[1].TraceId);
    TAssert.AssertEquals('the query is left out', BASE + '/indexes/products/documents',
      MeiliAttr(LSpans[1], 'url.full'));
    TAssert.AssertEquals('202', MeiliAttr(LSpans[1], 'http.response.status_code'));
    TAssert.AssertEquals(PcFormatTraceParent(LSpans[1].TraceId, LSpans[1].SpanId, True),
      FFake.Request(1).Header('traceparent'));
    TAssert.AssertEquals('the key goes in a header', 'Bearer secret',
      FFake.Request(1).Header('Authorization'));
    TAssert.AssertEquals(MEILISEARCH_WAIT_SPAN, LSpans[2].Name);
    TAssert.AssertTrue('an internal span', LSpans[2].Kind = skInternal);
    TAssert.AssertEquals(LParent.SpanId, LSpans[2].ParentSpanId);
    TAssert.AssertEquals('7', MeiliAttr(LSpans[2], 'meilisearch.task.uid'));
    TAssert.AssertEquals('3', MeiliAttr(LSpans[2], 'meilisearch.task.polls'));
    TAssert.AssertEquals('succeeded', MeiliAttr(LSpans[2], 'meilisearch.task.status'));
    TAssert.AssertTrue('a succeeded task is no error', LSpans[2].Status = ssUnset);
    // The polls: no span and no traceparent, but the metric.
    for I := 2 to 4 do
    begin
      TAssert.AssertEquals('GET /tasks/7', Req(I));
      TAssert.AssertEquals('', FFake.Request(I).Header('traceparent'));
    end;
    TAssert.AssertEquals(Int64(LGets + 4), Int64(MeiliDurationCount('GET')));
    TAssert.AssertEquals(Int64(LPosts + 1), Int64(MeiliDurationCount('POST')));
    LParent := nil;
    W := nil;
  finally
    TPcTracing.Shutdown;
  end;
end;

procedure TMeilisearchTests.Telemetry_NoCurrentSpan_NoSpanOnlyTheMetric;
var
  LExporterObj: TMeiliSpanExporter;
  LExporter: IPcSpanExporter;
  LGets: UInt64;
  I: Integer;
begin
  LExporterObj := TMeiliSpanExporter.Create;
  LExporter := LExporterObj;
  TPcTracing.Start(TPcTracingOptions.Default('search-tests', '1.0.0'), LExporter, False);
  try
    LGets := MeiliDurationCount('GET');
    IndexFound;
    Accepted(8);
    Task(8, 'processing');
    Task(8, 'failed', '{"message":"Document has a bad field.","code":"invalid_document_fields",' +
      '"type":"invalid_request"}');
    try
      FEngine.Index('products').Upsert([TSearchDocument.New('1')]).WaitFor;
      TAssert.Fail('A failed task must raise');
    except
      on ESearchWriteFailed do
        ;
    end;
    TPcTracing.FlushNow;
    TAssert.AssertEquals(0, Length(LExporterObj.Spans));
    for I := 0 to FFake.RequestCount - 1 do
      TAssert.AssertEquals('', FFake.Request(I).Header('traceparent'));
    TAssert.AssertEquals(Int64(LGets + 3), Int64(MeiliDurationCount('GET')));
  finally
    TPcTracing.Shutdown;
  end;
end;

procedure TMeilisearchTests.Telemetry_FailedTaskOrTimeout_WaitSpanIsAnError;
var
  LExporterObj: TMeiliSpanExporter;
  LExporter: IPcSpanExporter;
  LParent: IPcSpan;
  LSpans: TPcSpanDataArray;
begin
  LExporterObj := TMeiliSpanExporter.Create;
  LExporter := LExporterObj;
  TPcTracing.Start(TPcTracingOptions.Default('search-tests', '1.0.0'), LExporter, False);
  try
    LParent := TPcTracing.StartSpan('handler', skServer);
    try
      Task(4, 'failed', '{"message":"Document has a bad field.","code":"invalid_document_fields",' +
        '"type":"invalid_request"}');
      try
        FEngine.WaitForTask(4);
        TAssert.Fail('A failed task must raise');
      except
        on ESearchRequestError do
          ;
      end;
      Task(5, 'processing');
      Task(5, 'processing');
      try
        FEngine.WaitForTask(5, 5);
        TAssert.Fail('A task still running must time out');
      except
        on ESearchTimeout do
          ;
      end;
    finally
      LParent.Finish;
    end;
    TPcTracing.FlushNow;
    LSpans := LExporterObj.Spans;
    // The two waits, the handler.
    TAssert.AssertEquals(3, Length(LSpans));
    TAssert.AssertEquals(MEILISEARCH_WAIT_SPAN, LSpans[0].Name);
    TAssert.AssertTrue('a failed task is an error', LSpans[0].Status = ssError);
    TAssert.AssertEquals('invalid_document_fields', MeiliAttr(LSpans[0], 'error.type'));
    TAssert.AssertEquals('Document has a bad field.', LSpans[0].StatusMessage);
    TAssert.AssertEquals('failed', MeiliAttr(LSpans[0], 'meilisearch.task.status'));
    TAssert.AssertEquals('1', MeiliAttr(LSpans[0], 'meilisearch.task.polls'));
    TAssert.AssertTrue('a timeout is an error', LSpans[1].Status = ssError);
    TAssert.AssertEquals('ESearchTimeout', MeiliAttr(LSpans[1], 'error.type'));
    TAssert.AssertEquals('2', MeiliAttr(LSpans[1], 'meilisearch.task.polls'));
    TAssert.AssertEquals('5', MeiliAttr(LSpans[1], 'meilisearch.task.uid'));
    LParent := nil;
  finally
    TPcTracing.Shutdown;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMeilisearchTests);

end.
