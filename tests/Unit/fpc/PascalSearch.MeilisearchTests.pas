unit PascalSearch.MeilisearchTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalSearch.MeilisearchTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

(* The Meilisearch adapter without a server: every request goes to
   pascal-common-faa's TPcFakeHttpTransport, which answers from a queue and
   keeps what was sent. The tests check what the adapter sends (method, URL,
   key, body) and how it reads each answer (2xx, Meilisearch's errors, a lost
   connection), plus the filter text with the probe's hostile values
   (docs/design.md, S13 and S24). Task polling runs on a fake clock: TSleep
   advances TTicker, so nothing sleeps.

   What Meilisearch itself does with these requests is the integration
   suite's job (tests/Integration).

   DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
   PascalSearch.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
   the master by tools/gen_fpc_mirror.py: edit only the master. *)

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalCommon.SystemContext,
  PascalCommon.Http,
  PascalCommon.Http.Fake,
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

  TMeilisearchTests = class(TTestCase)
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published

    procedure Filter_StringsQuotedAndEscaped;
    procedure Filter_EveryOperator;
    procedure Filter_NumbersPlainInstantsInMs;

    procedure Config_BadUrl_ArgumentError;
    procedure EnsureIndex_New_CreatesAndSendsSettings;
    procedure EnsureIndex_Existing_SettingsOnly;
    procedure EnsureIndex_OtherPrimaryKey_SchemaError;
    procedure EnsureIndex_CreatedMeanwhile_NoError;

    procedure Upsert_SendsDocuments_WaitForPolls;
    procedure Upsert_TaskFailed_WholeBatch;
    procedure Upsert_IndexMissing_NothingSent;
    procedure Upsert_Empty_NoTask;
    procedure Write_NoAnswer_Unavailable;
    procedure WaitFor_Timeout;
    procedure Pending_AsksOnceDone;
    procedure Delete_SendsIds;
    procedure DeleteWhere_Failed_RequestError;

    procedure Search_RequestBody;
    procedure Search_RawReplacesParameter;
    procedure Search_ReadsAnswer;
    procedure Search_PastMaxHits_ReadsSettingsOnce;
    procedure Errors_Mapped;

    procedure Get_FoundMissingAndNoIndex;
    procedure GetMany_OrderAsked;
    procedure DropIndex_Missing_NoError;
    procedure Send_NativeAccess;
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

initialization
  RegisterTest(TMeilisearchTests);

end.
