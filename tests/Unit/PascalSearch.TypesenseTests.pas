unit PascalSearch.TypesenseTests;

(* The Typesense adapter without a server: every request goes to
   pascal-common-faa's TPcFakeHttpTransport, which answers from a queue and
   keeps what was sent. The tests check what the adapter sends (method, URL
   with its encoded query, key, body) and how it reads each answer, the
   schema kept in the collection's metadata, the checks the adapter makes
   itself (filter, sort and facet fields, MaxHits), and the filter text with
   the probe's hostile values (docs/design.md, S13 and S24). 0.2.0: an index
   is an alias to a collection named with TClock (fixed here), ReplaceIndex,
   ListIds, synonym and curation sets, highlight (section 12).

   What Typesense itself does with these requests is the integration
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
  PascalCommon.Http,
  PascalCommon.Http.Fake,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Typesense;

type
  TFixedClock = class(TInterfacedObject, IClock)
  public
    function Now: TDateTime;
    function Date: TDateTime;
  end;

  TFakeTicker = class(TInterfacedObject, ITicker)
  private
    FNow: UInt64;
  public
    function NowMs: UInt64;
    procedure Advance(AMs: Integer);
  end;

  [TestFixture]
  TTypesenseTests = class
  private
    FFake: TPcFakeHttpTransport;
    FTransport: IPcHttpTransport;
    FEngine: ITypesenseEngine;
    procedure Ok(const ABody: string);
    procedure Collection;
    procedure NoCollection;
    function Req(AIndex: Integer): string;
    procedure ExpectRequestError(const AQuery: ISearchQuery; const AField: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Filter_StringsInBackticks;
    [Test] procedure Filter_Backtick_Refused;
    [Test] procedure Filter_EveryOperator;
    [Test] procedure Filter_NumbersPlainInstantsInMs;

    [Test] procedure Config_BadUrl_ArgumentError;
    [Test] procedure CollectionJson_FieldsAndMetadata;
    [Test] procedure EnsureIndex_New_PostsCollection;
    [Test] procedure EnsureIndex_Same_MetadataOnly;
    [Test] procedure EnsureIndex_FlagsChanged_DropAndAdd;
    [Test] procedure EnsureIndex_KindChanged_SchemaError;
    [Test] procedure EnsureIndex_NameTaken_Suffix;

    [Test] procedure Upsert_ImportLines_SomeRefused;
    [Test] procedure Upsert_AllRefused_WholeBatch;
    [Test] procedure Upsert_NoCollection_NothingSent;
    [Test] procedure Write_NoAnswer_Unavailable;
    [Test] procedure Delete_ByIdFilter;
    [Test] procedure DeleteWhere_ChecksTheSchema;

    [Test] procedure Search_Url;
    [Test] procedure Search_BlankText_Star;
    [Test] procedure Search_RawReplacesParameter;
    [Test] procedure Search_ReadsAnswer_CutsAtMaxHits;
    [Test] procedure Search_UndeclaredFields_NothingSent;
    [Test] procedure Search_PastMaxHits;
    [Test] procedure Search_NoTextFields_MatchesNothing;
    [Test] procedure Schema_ReadOnce_FromCollectionWithoutMetadata;
    [Test] procedure Errors_Mapped;

    [Test] procedure Get_FoundMissingAndNoCollection;
    [Test] procedure GetMany_OrderAsked;
    [Test] procedure DropIndex_AliasCollectionAndSets;
    [Test] procedure DropIndex_OldCollectionOrMissing;
    [Test] procedure Send_NativeAccess;

    [Test] procedure ReplaceIndex_MovesTheAlias;
    [Test] procedure ReplaceIndex_OldCollection_DroppedFirst;
    [Test] procedure ReplaceIndex_SourceWithoutAlias;
    [Test] procedure ListIds_Export;
    [Test] procedure SetSynonyms_PutsSetAndAttaches;
    [Test] procedure SetCuration_PutsSet;
    [Test] procedure Search_Highlight;
    [Test] procedure Schema_CacheExpires;
  end;

implementation

const
  BASE = 'http://ts:8108';
  NOT_FOUND = '{"message":"Collection not found"}';
  // The collection of Schema below, as Typesense returns it (fields cut).
  COLLECTION_JSON = '{"name":"products","num_documents":7,"fields":[' +
    '{"name":"title","type":"string","optional":true,"facet":false,"sort":false,"index":true},' +
    '{"name":"category","type":"string","optional":true,"facet":true,"sort":false,"index":true},' +
    '{"name":"price","type":"float","optional":true,"facet":false,"sort":true,"index":true}],' +
    '"metadata":{"pascal_search":{"version":1,"max_hits":5,"fields":[' +
    '{"name":"title","kind":"text","flags":[]},' +
    '{"name":"category","kind":"keyword","flags":["filter","facet"]},' +
    '{"name":"price","kind":"number","flags":["filter","sort"]},' +
    '{"name":"note","kind":"stored","flags":[]}]}}}';
  META = '"metadata":{"pascal_search":{"version":1,"max_hits":5,"fields":[' +
    '{"name":"title","kind":"text","flags":[]},' +
    '{"name":"category","kind":"keyword","flags":["filter","facet"]},' +
    '{"name":"price","kind":"number","flags":["filter","sort"]},' +
    '{"name":"note","kind":"stored","flags":[]}]}}';

function CollectionName: string;
begin
  Result := 'products@' + IntToStr(SearchInstantToMs(EncodeDate(2026, 11, 11)));
end;

{ TFakeTicker }

function TFakeTicker.NowMs: UInt64;
begin
  Result := FNow;
end;

procedure TFakeTicker.Advance(AMs: Integer);
begin
  Inc(FNow, AMs);
end;

{ TFixedClock }

function TFixedClock.Now: TDateTime;
begin
  Result := EncodeDate(2026, 11, 11);
end;

function TFixedClock.Date: TDateTime;
begin
  Result := EncodeDate(2026, 11, 11);
end;

function Schema: ISearchSchema;
begin
  Result := TSearchSchema.New('products')
    .Text('title')
    .Keyword('category', [sfFilter, sfFacet])
    .Num('price', [sfFilter, sfSort])
    .Stored('note')
    .WithMaxHits(5);
end;

{ TTypesenseTests }

procedure TTypesenseTests.Setup;
begin
  FFake := TPcFakeHttpTransport.Create;
  FTransport := FFake;
  FEngine := TTypesenseEngine.New(TTypesenseConfig.Create(BASE, 'secret'), FTransport);
  TClock.SetClock(TFixedClock.Create);
end;

procedure TTypesenseTests.TearDown;
begin
  TClock.Reset;
  TTicker.Reset;
  FEngine := nil;
  FTransport := nil;
  FFake := nil;
end;

procedure TTypesenseTests.Ok(const ABody: string);
begin
  FFake.Answer(200, ABody);
end;

procedure TTypesenseTests.Collection;
begin
  Ok(COLLECTION_JSON);
end;

procedure TTypesenseTests.NoCollection;
begin
  FFake.Answer(404, NOT_FOUND);
end;

// "METHOD url" of request AIndex, the base cut off.
function TTypesenseTests.Req(AIndex: Integer): string;
var
  R: TPcHttpRequest;
begin
  R := FFake.Request(AIndex);
  Result := R.Method + ' ' + StringReplace(R.Url, BASE, '', []);
end;

procedure TTypesenseTests.ExpectRequestError(const AQuery: ISearchQuery; const AField: string);
begin
  try
    AQuery.Execute;
    TAssert.Fail('A query on "' + AField + '" must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('"' + AField + '"', E.Message) > 0);
  end;
end;

procedure TTypesenseTests.Filter_StringsInBackticks;
begin
  TAssert.AssertEquals('category:=`bebida`', TypesenseFilterText(F.Eq('category', 'bebida')));
  TAssert.AssertEquals('category:=`Bar "Zé"`', TypesenseFilterText(F.Eq('category', 'Bar "Zé"')));
  TAssert.AssertEquals('category:=`C:\doces\`', TypesenseFilterText(F.Eq('category', 'C:\doces\')));
  TAssert.AssertEquals('category:=`bebida || price:>0`',
    TypesenseFilterText(F.Eq('category', 'bebida || price:>0')));
  TAssert.AssertEquals('category:=`a)b && (c`', TypesenseFilterText(F.Eq('category', 'a)b && (c')));
end;

procedure TTypesenseTests.Filter_Backtick_Refused;
begin
  try
    TypesenseFilterText(F.Eq('category', 'x''y`z, w'));
    TAssert.Fail('A backtick in a value must raise');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('backtick', E.Message) > 0);
  end;
  try
    TypesenseFilterText(F.All([F.Gt('price', Int64(0)), F.NoneOf('tags', ['ok', '`'])]));
    TAssert.Fail('A backtick inside a group must raise');
  except
    on ESearchArgumentError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseTests.Filter_EveryOperator;
begin
  TAssert.AssertEquals('category:!=`bebida`', TypesenseFilterText(F.NotEq('category', 'bebida')));
  TAssert.AssertEquals('id:=`1`', TypesenseFilterText(F.AnyOf('id', ['1'])));
  TAssert.AssertEquals('(id:=`1` || id:=`7`)', TypesenseFilterText(F.AnyOf('id', ['1', '7'])));
  TAssert.AssertEquals('(category:!=`C:\doces\` && category:!=`b`)',
    TypesenseFilterText(F.NoneOf('category', ['C:\doces\', 'b'])));
  TAssert.AssertEquals('stock:>0', TypesenseFilterText(F.Gt('stock', Int64(0))));
  TAssert.AssertEquals('stock:>=1', TypesenseFilterText(F.Ge('stock', Int64(1))));
  TAssert.AssertEquals('stock:<2', TypesenseFilterText(F.Lt('stock', Int64(2))));
  TAssert.AssertEquals('stock:<=3', TypesenseFilterText(F.Le('stock', Int64(3))));
  TAssert.AssertEquals('price:[5..8.5]', TypesenseFilterText(F.Between('price', 5.0, 8.5)));
  TAssert.AssertEquals('(available:=true) && ((stock:>0) || (available:=false))',
    TypesenseFilterText(F.All([F.Eq('available', True),
      F.Any([F.Gt('stock', Int64(0)), F.Eq('available', False)])])));
end;

procedure TTypesenseTests.Filter_NumbersPlainInstantsInMs;
begin
  TAssert.AssertEquals('price:>1000000000000000000000', TypesenseFilterText(F.Gt('price', 1e21)));
  TAssert.AssertEquals('price:<0.00000015', TypesenseFilterText(F.Lt('price', 1.5e-7)));
  TAssert.AssertEquals('created_at:>=1767225600000',
    TypesenseFilterText(F.Ge('created_at', F.At(EncodeDate(2026, 1, 1)))));
end;

procedure TTypesenseTests.Config_BadUrl_ArgumentError;
const
  BAD: array[0..2] of string = ('', 'http://ts:8108/x', 'http://t s');
var
  I: Integer;
begin
  for I := 0 to High(BAD) do
    try
      TTypesenseEngine.New(TTypesenseConfig.Create(BAD[I]), FTransport);
      TAssert.Fail('Accepted the URL "' + BAD[I] + '"');
    except
      on E: ESearchArgumentError do
        TAssert.AssertTrue(E.Message, Pos('URL', E.Message) > 0);
    end;
end;

procedure TTypesenseTests.CollectionJson_FieldsAndMetadata;
begin
  TAssert.AssertEquals('{"name":"products","fields":[' +
    '{"name":"title","type":"string","optional":true,"facet":false,"sort":false},' +
    '{"name":"category","type":"string","optional":true,"facet":true,"sort":false},' +
    '{"name":"price","type":"float","optional":true,"facet":false,"sort":true}],' + META + '}',
    TypesenseCollectionJson(Schema));
  TAssert.AssertEquals('kinds', '{"name":"k","fields":[' +
    '{"name":"a","type":"string[]","optional":true,"facet":true,"sort":false},' +
    '{"name":"b","type":"int64","optional":true,"facet":false,"sort":true},' +
    '{"name":"c","type":"int64","optional":true,"facet":false,"sort":false},' +
    '{"name":"d","type":"bool","optional":true,"facet":true,"sort":false}],' +
    '"metadata":{"pascal_search":{"version":1,"max_hits":1000,"fields":[' +
    '{"name":"a","kind":"keywords","flags":["facet"]},{"name":"b","kind":"integer","flags":["sort"]},' +
    '{"name":"c","kind":"instant","flags":["filter"]},{"name":"d","kind":"boolean","flags":["facet"]},' +
    '{"name":"e","kind":"keyword","flags":[]}]}}}',
    TypesenseCollectionJson(TSearchSchema.New('k').Keywords('a', [sfFacet]).Int('b', [sfSort])
      .Instant('c', [sfFilter]).Bool('d', [sfFacet]).Keyword('e')));
end;

procedure TTypesenseTests.EnsureIndex_New_PostsCollection;
var
  LIndex: ISearchIndex;
begin
  NoCollection;
  FFake.Answer(201, COLLECTION_JSON);
  Ok('{}');
  LIndex := FEngine.EnsureIndex(Schema);
  TAssert.AssertEquals('products', LIndex.Name);
  TAssert.AssertEquals(3, FFake.RequestCount);
  TAssert.AssertEquals('GET /collections/products', Req(0));
  TAssert.AssertEquals('secret', FFake.Request(0).Header('X-TYPESENSE-API-KEY'));
  TAssert.AssertEquals('POST /collections', Req(1));
  TAssert.AssertEquals(TypesenseCollectionJson(Schema, CollectionName), FFake.Request(1).Body);
  TAssert.AssertTrue(Pos('{"name":"products@', FFake.Request(1).Body) = 1);
  TAssert.AssertEquals('PUT /aliases/products', Req(2));
  TAssert.AssertEquals('{"collection_name":"' + CollectionName + '"}', FFake.Request(2).Body);
  // The schema is known now: a search asks for nothing but the search.
  Ok('{"found":0,"hits":[]}');
  LIndex.Search('').Execute;
  TAssert.AssertEquals(4, FFake.RequestCount);
end;

procedure TTypesenseTests.EnsureIndex_Same_MetadataOnly;
begin
  Collection;
  Ok('{}');
  FEngine.EnsureIndex(Schema);
  TAssert.AssertEquals('PATCH /collections/products', Req(1));
  TAssert.AssertEquals('{' + META + '}', FFake.Request(1).Body);
end;

procedure TTypesenseTests.EnsureIndex_FlagsChanged_DropAndAdd;
begin
  Collection;
  Ok('{}');
  FEngine.EnsureIndex(TSearchSchema.New('products')
    .Text('title')
    .Keyword('category', [sfFilter])              // no longer a facet
    .Num('price')                                 // no flags: not indexed
    .Int('stock', [sfSort]));                     // new
  TAssert.AssertEquals('{"fields":[' +
    '{"name":"category","drop":true},' +
    '{"name":"category","type":"string","optional":true,"facet":false,"sort":false},' +
    '{"name":"price","drop":true},' +
    '{"name":"stock","type":"int64","optional":true,"facet":false,"sort":true}],' +
    '"metadata":{"pascal_search":{"version":1,"max_hits":1000,"fields":[' +
    '{"name":"title","kind":"text","flags":[]},{"name":"category","kind":"keyword","flags":["filter"]},' +
    '{"name":"price","kind":"number","flags":[]},{"name":"stock","kind":"integer","flags":["sort"]}]}}}',
    FFake.Request(1).Body);
end;

procedure TTypesenseTests.EnsureIndex_KindChanged_SchemaError;
begin
  Collection;
  try
    FEngine.EnsureIndex(TSearchSchema.New('products').Keyword('title'));
    TAssert.Fail('A kind change must raise');
  except
    on E: ESearchSchemaError do
      TAssert.AssertTrue(E.Message, Pos('"title" is text', E.Message) > 0);
  end;
  TAssert.AssertEquals('nothing changed', 1, FFake.RequestCount);
end;

procedure TTypesenseTests.EnsureIndex_NameTaken_Suffix;
begin
  NoCollection;
  FFake.Answer(409, '{"message":"A collection with name `x` already exists."}');
  FFake.Answer(201, '{}');
  Ok('{}');
  FEngine.EnsureIndex(Schema);
  TAssert.AssertEquals(4, FFake.RequestCount);
  TAssert.AssertTrue(Pos('{"name":"' + CollectionName + '_2"', FFake.Request(2).Body) = 1);
  TAssert.AssertEquals('PUT /aliases/products', Req(3));
  TAssert.AssertEquals('{"collection_name":"' + CollectionName + '_2"}', FFake.Request(3).Body);
end;

procedure TTypesenseTests.Upsert_ImportLines_SomeRefused;
var
  W: ISearchWrite;
begin
  Collection;
  Ok('{"success":true}'#10'{"code":400,"error":"Field `price` must be a float.","success":false}'#10 +
    '{"success":true}');
  W := FEngine.Index('products').Upsert([
    TSearchDocument.New('1').Str('title', 'Café'),
    TSearchDocument.New('2').Str('price', 'abc'),
    TSearchDocument.New('3')]);
  TAssert.AssertEquals('POST /collections/products/documents/import?action=upsert', Req(1));
  TAssert.AssertEquals('{"id":"1","title":"Café"}'#10'{"id":"2","price":"abc"}'#10'{"id":"3"}',
    FFake.Request(1).Body);
  TAssert.AssertFalse(W.Pending);
  try
    W.WaitFor;
    TAssert.Fail('A refused document must raise');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertFalse(E.WholeBatch);
      TAssert.AssertEquals(1, Length(E.Failures));
      TAssert.AssertEquals('2', E.Failures[0].Id);
      TAssert.AssertEquals('400', E.Failures[0].Code);
      TAssert.AssertEquals('Field `price` must be a float.', E.Failures[0].Message);
    end;
  end;
end;

procedure TTypesenseTests.Upsert_AllRefused_WholeBatch;
var
  W: ISearchWrite;
begin
  Collection;
  Ok('{"code":400,"error":"bad","success":false}');
  W := FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
  try
    W.WaitFor;
    TAssert.Fail('A refused document must raise');
  except
    on E: ESearchWriteFailed do
      TAssert.AssertTrue(E.WholeBatch);
  end;
end;

procedure TTypesenseTests.Upsert_NoCollection_NothingSent;
begin
  NoCollection;
  try
    FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
    TAssert.Fail('A write to a missing collection must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos('products', E.Message) > 0);
  end;
  TAssert.AssertEquals(1, FFake.RequestCount);
end;

procedure TTypesenseTests.Write_NoAnswer_Unavailable;
begin
  Collection;
  FFake.Fail('POST http://ts:8108/collections/products/documents/import: no answer (reset)');
  try
    FEngine.Index('products').Upsert([TSearchDocument.New('1')]);
    TAssert.Fail('A write without an answer must raise');
  except
    on E: ESearchUnavailable do
      TAssert.AssertTrue(E.Message, Pos('reset', E.Message) > 0);
  end;
  TAssert.AssertEquals('sent once', 2, FFake.RequestCount);
end;

procedure TTypesenseTests.Delete_ByIdFilter;
var
  W: ISearchWrite;
begin
  Collection;
  Ok('{"num_deleted":1}');
  W := FEngine.Index('products').Delete(['1', 'a-b_c']);
  TAssert.AssertEquals('DELETE /collections/products/documents?filter_by=id%3A%5B%601%60%2C%60a-b_c%60%5D',
    Req(1));
  W.WaitFor;
  TAssert.AssertFalse(W.Pending);
end;

procedure TTypesenseTests.DeleteWhere_ChecksTheSchema;
begin
  Collection;
  Ok('{"num_deleted":2}');
  FEngine.Index('products').DeleteWhere(F.Eq('category', 'bebida'));
  TAssert.AssertEquals('DELETE /collections/products/documents?filter_by=category%3A%3D%60bebida%60', Req(1));
  try
    FEngine.Index('products').DeleteWhere(F.Eq('title', 'x'));
    TAssert.Fail('A filter on a field not declared filterable must raise');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('"title"', E.Message) > 0);
  end;
  TAssert.AssertEquals('nothing sent', 2, FFake.RequestCount);
end;

procedure TTypesenseTests.Search_Url;
begin
  Collection;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('-café "preto"')
    .Where(F.Eq('category', 'bebida'))
    .OrderBy('price', soDesc)
    .Page(1, 2)
    .Facets(['category'])
    .Fields(['title'])
    .Execute;
  TAssert.AssertEquals('GET /collections/products/documents/search?q=caf%C3%A9%20preto&query_by=title' +
    '&drop_tokens_threshold=0&filter_by=category%3A%3D%60bebida%60&sort_by=price%3Adesc&page=1&per_page=2' +
    '&facet_by=category&max_facet_values=100&include_fields=title%2Cid', Req(1));
  TAssert.AssertEquals('', FFake.Request(1).Body);
end;

procedure TTypesenseTests.Search_BlankText_Star;
begin
  Collection;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('  ').Words(swRelaxed).Page(1, 0).Execute;
  TAssert.AssertEquals('GET /collections/products/documents/search?q=%2A&drop_tokens_threshold=1' +
    '&page=1&per_page=0', Req(1));
end;

procedure TTypesenseTests.Search_RawReplacesParameter;
begin
  Collection;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('x')
    .Raw('drop_tokens_threshold', '2')
    .Raw('highlight_fields', '"title"')
    .Execute;
  TAssert.AssertEquals('GET /collections/products/documents/search?q=x&query_by=title&page=1&per_page=20' +
    '&drop_tokens_threshold=2&highlight_fields=title', Req(1));
end;

procedure TTypesenseTests.Search_ReadsAnswer_CutsAtMaxHits;
const
  ANSWER = '{"facet_counts":[{"counts":[{"count":1,"highlighted":"x","value":"Bar \"Zé\""},' +
    '{"count":2,"highlighted":"b","value":"bebida"}],"field_name":"category","sampled":false}],' +
    '"found":7,"hits":[{"document":{"id":"4","title":"Água"},"text_match":1},' +
    '{"document":{"id":"7","title":"Quindim"}},{"document":{"id":"9","title":"past MaxHits"}}],' +
    '"out_of":7,"page":2,"search_time_ms":0}';
var
  R: ISearchResult;
  LFacet: TSearchFacet;
begin
  Collection;
  Ok(ANSWER);
  R := FEngine.Index('products').Search('').Page(2, 3).Facets(['category']).Execute;
  TAssert.AssertEquals(Int64(7), R.Total);
  TAssert.AssertEquals('positions 3 and 4 only (MaxHits 5)', 2, R.Count);
  TAssert.AssertEquals('4', R.Hit(0).Id);
  TAssert.AssertEquals('Quindim', R.Hit(1).Document.Find('title').AsString);
  TAssert.AssertEquals(ANSWER, R.RawJson);
  TAssert.AssertTrue(R.FindFacet('category', LFacet));
  TAssert.AssertEquals('bebida', LFacet.Values[0].Value);
  TAssert.AssertEquals(2, LFacet.Values[0].Count);
  TAssert.AssertEquals('Bar "Zé"', LFacet.Values[1].Value);
end;

procedure TTypesenseTests.Search_UndeclaredFields_NothingSent;
var
  LIndex: ISearchIndex;
begin
  Collection;
  LIndex := FEngine.Index('products');
  ExpectRequestError(LIndex.Search('').Where(F.Eq('title', 'x')), 'title');
  ExpectRequestError(LIndex.Search('').Where(F.Any([F.Gt('price', 1.0), F.Eq('note', 'x')])), 'note');
  ExpectRequestError(LIndex.Search('').OrderBy('category'), 'category');
  ExpectRequestError(LIndex.Search('').Facets(['price']), 'price');
  TAssert.AssertEquals('only the collection, once', 1, FFake.RequestCount);
end;

procedure TTypesenseTests.Search_PastMaxHits;
begin
  Collection;
  try
    FEngine.Index('products').Search('').Page(2, 5).Execute;
    TAssert.Fail('A page past MaxHits must raise');
  except
    on E: ESearchArgumentError do
      TAssert.AssertTrue(E.Message, Pos('MaxHits (5)', E.Message) > 0);
  end;
end;

procedure TTypesenseTests.Search_NoTextFields_MatchesNothing;
var
  R: ISearchResult;
  LFacet: TSearchFacet;
begin
  NoCollection;
  FFake.Answer(201, '{}');
  Ok('{}');
  FEngine.EnsureIndex(TSearchSchema.New('codes').Keyword('code', [sfFilter, sfFacet]));
  R := FEngine.Index('codes').Search('abc').Facets(['code']).Execute;
  TAssert.AssertEquals(Int64(0), R.Total);
  TAssert.AssertTrue(R.FindFacet('code', LFacet));
  TAssert.AssertEquals('no request: nothing to search the words in', 3, FFake.RequestCount);
end;

procedure TTypesenseTests.Schema_ReadOnce_FromCollectionWithoutMetadata;
var
  LIndex: ISearchIndex;
begin
  Ok('{"name":"other","fields":[{"name":"title","type":"string","facet":false,"sort":false},' +
    '{"name":"tags","type":"string[]","facet":true},{"name":"n","type":"int32","sort":true},' +
    '{"name":"hidden","type":"string","index":false}]}');
  LIndex := FEngine.Index('other');
  Ok('{"found":0,"hits":[]}');
  LIndex.Search('x').Where(F.Eq('tags', 'a')).OrderBy('n').Facets(['tags']).Execute;
  TAssert.AssertEquals('GET /collections/other/documents/search?q=x&query_by=title&drop_tokens_threshold=0' +
    '&filter_by=tags%3A%3D%60a%60&sort_by=n%3Aasc&page=1&per_page=20&facet_by=tags&max_facet_values=100',
    Req(1));
  ExpectRequestError(LIndex.Search('').Where(F.Eq('hidden', 'x')), 'hidden');
  TAssert.AssertEquals(2, FFake.RequestCount);
end;

procedure TTypesenseTests.Errors_Mapped;

  procedure Check(AStatus: Integer; const ABody: string; AClass: ExceptClass);
  begin
    FFake.Answer(AStatus, ABody);
    try
      FEngine.Send('GET', '/collections/products/documents/search?q=x');
      TAssert.Fail(Format('HTTP %d must raise', [AStatus]));
    except
      on E: ESearchError do
      begin
        TAssert.AssertEquals(Format('HTTP %d: %s', [AStatus, E.Message]), AClass.ClassName, E.ClassName);
        TAssert.AssertEquals(AStatus, E.HttpStatus);
        TAssert.AssertEquals('Typesense sends no code', '', E.EngineCode);
      end;
    end;
  end;

begin
  Check(401, '{"message": "Forbidden - a valid `x-typesense-api-key` header must be sent."}', ESearchAuthError);
  Check(404, NOT_FOUND, ESearchIndexNotFound);
  Check(404, '{"message":"Could not find a field named `body` in the schema for sorting."}',
    ESearchRequestError);
  Check(400, '{"message":"Could not parse the filter query."}', ESearchRequestError);
  Check(422, '{"message":"Only upto 250 hits can be fetched per page."}', ESearchRequestError);
  Check(503, '{"message":"Not Ready or Lagging"}', ESearchUnavailable);
  Check(502, '<html>Bad Gateway</html>', ESearchUnavailable);
end;

procedure TTypesenseTests.Get_FoundMissingAndNoCollection;
var
  H: ISearchHit;
begin
  Ok('{"id":"1","title":"Café"}');
  H := FEngine.Index('products').Get('1');
  TAssert.AssertEquals('GET /collections/products/documents/1', Req(0));
  TAssert.AssertEquals('Café', H.Document.Find('title').AsString);
  FFake.Answer(404, '{"message":"Could not find a document with id: 2"}');
  TAssert.AssertTrue(FEngine.Index('products').Get('2') = nil);
  NoCollection;
  try
    FEngine.Index('products').Get('3');
    TAssert.Fail('Get on a missing collection must raise');
  except
    on ESearchIndexNotFound do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseTests.GetMany_OrderAsked;
var
  H: ISearchHits;
begin
  Collection;
  Ok('{"found":2,"hits":[{"document":{"id":"1","title":"a"}},{"document":{"id":"3","title":"c"}}]}');
  H := FEngine.Index('products').GetMany(['3', 'nope', '1', '3']);
  TAssert.AssertEquals('GET /collections/products/documents/search?q=*&filter_by=' +
    'id%3A%5B%603%60%2C%60nope%60%2C%601%60%5D&per_page=3', Req(1));
  TAssert.AssertEquals(3, H.Count);
  TAssert.AssertEquals('3', H.Hit(0).Id);
  TAssert.AssertEquals('1', H.Hit(1).Id);
  TAssert.AssertEquals('c', H.Hit(2).Document.Find('title').AsString);
end;

procedure TTypesenseTests.DropIndex_AliasCollectionAndSets;
begin
  Ok('{"collection_name":"products@1","name":"products"}');
  Ok(COLLECTION_JSON);
  Ok('{}');
  FFake.Answer(404, '{"message":"Not Found"}');
  FFake.Answer(404, '{"message":"Not Found"}');
  FEngine.DropIndex('products');
  TAssert.AssertEquals(5, FFake.RequestCount);
  TAssert.AssertEquals('GET /aliases/products', Req(0));
  TAssert.AssertEquals('DELETE /collections/products%401', Req(1));
  TAssert.AssertEquals('DELETE /aliases/products', Req(2));
  TAssert.AssertEquals('the sets after the collection', 'DELETE /synonym_sets/products%401', Req(3));
  TAssert.AssertEquals('DELETE /curation_sets/products%401', Req(4));
end;

procedure TTypesenseTests.DropIndex_OldCollectionOrMissing;
begin
  NoCollection;
  Ok(COLLECTION_JSON);
  Ok('{}');
  Ok('{}');
  FEngine.DropIndex('products');
  TAssert.AssertEquals('a 0.1.0 collection named like the index', 'DELETE /collections/products', Req(1));
  TAssert.AssertEquals('DELETE /synonym_sets/products', Req(2));
  NoCollection;
  NoCollection;
  FFake.Answer(404, '{"message":"Not Found"}');
  FFake.Answer(404, '{"message":"Not Found"}');
  FEngine.DropIndex('products');
  TAssert.AssertEquals('missing: no error', 8, FFake.RequestCount);
  FFake.Answer(503, '{"message":"Not Ready or Lagging"}');
  try
    FEngine.DropIndex('products');
    TAssert.Fail('A 503 must raise');
  except
    on ESearchUnavailable do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseTests.Send_NativeAccess;
begin
  Ok('[]');
  TAssert.AssertEquals('[]', FEngine.Send('GET', '/synonym_sets'));
  TAssert.AssertEquals('secret', FFake.Request(0).Header('X-TYPESENSE-API-KEY'));
  TAssert.AssertEquals('', FFake.Request(0).Header('Content-Type'));
  Ok('{}');
  FEngine.Send('PUT', '/synonym_sets/s1', '{"items":[]}');
  TAssert.AssertEquals('application/json', FFake.Request(1).Header('Content-Type'));
end;

procedure TTypesenseTests.ReplaceIndex_MovesTheAlias;
begin
  Ok('{"collection_name":"products_new@2","name":"products_new"}');
  Ok('{"name":"products_new@2","fields":[]}');
  Ok('{"collection_name":"products@1","name":"products"}');
  Ok('{}');
  Ok('{}');
  Ok('{}');
  FFake.Answer(404, '{"message":"Not Found"}');
  FFake.Answer(404, '{"message":"Not Found"}');
  FEngine.ReplaceIndex('products', 'products_new');
  TAssert.AssertEquals(8, FFake.RequestCount);
  TAssert.AssertEquals('GET /aliases/products_new', Req(0));
  TAssert.AssertEquals('GET /collections/products_new', Req(1));
  TAssert.AssertEquals('GET /aliases/products', Req(2));
  TAssert.AssertEquals('PUT /aliases/products', Req(3));
  TAssert.AssertEquals('{"collection_name":"products_new@2"}', FFake.Request(3).Body);
  TAssert.AssertEquals('DELETE /aliases/products_new', Req(4));
  TAssert.AssertEquals('DELETE /collections/products%401', Req(5));
  TAssert.AssertEquals('DELETE /synonym_sets/products%401', Req(6));
  TAssert.AssertEquals('DELETE /curation_sets/products%401', Req(7));
end;

procedure TTypesenseTests.ReplaceIndex_OldCollection_DroppedFirst;
begin
  Ok('{"collection_name":"products_new@2","name":"products_new"}');
  Ok('{"name":"products_new@2","fields":[]}');
  NoCollection;
  Ok(COLLECTION_JSON);
  Ok('{}');
  Ok('{}');
  Ok('{}');
  Ok('{}');
  Ok('{}');
  FEngine.ReplaceIndex('products', 'products_new');
  TAssert.AssertEquals('GET /aliases/products', Req(2));
  TAssert.AssertEquals('GET /collections/products', Req(3));
  TAssert.AssertEquals('the name freed for the alias', 'DELETE /collections/products', Req(4));
  TAssert.AssertEquals('PUT /aliases/products', Req(5));
  TAssert.AssertEquals('DELETE /aliases/products_new', Req(6));
  TAssert.AssertEquals('DELETE /synonym_sets/products', Req(7));
  TAssert.AssertEquals('DELETE /curation_sets/products', Req(8));
  TAssert.AssertEquals(9, FFake.RequestCount);
end;

procedure TTypesenseTests.ReplaceIndex_SourceWithoutAlias;
begin
  NoCollection;
  Ok(COLLECTION_JSON);
  try
    FEngine.ReplaceIndex('products', 'products_new');
    TAssert.Fail('A 0.1.0 source must raise');
  except
    on E: ESearchNotSupported do
      TAssert.AssertTrue(E.Message, Pos('0.2.0', E.Message) > 0);
  end;
  NoCollection;
  NoCollection;
  try
    FEngine.ReplaceIndex('products', 'products_new');
    TAssert.Fail('A missing source must raise');
  except
    on ESearchIndexNotFound do
      TAssert.AssertEquals(4, FFake.RequestCount);
  end;
end;

procedure TTypesenseTests.ListIds_Export;
var
  LIds: TArray<string>;
begin
  Collection;
  Ok('{"id":"1"}'#10'{"id":"7"}'#10);
  LIds := FEngine.Index('products').ListIds;
  TAssert.AssertEquals('GET /collections/products/documents/export?include_fields=id', Req(1));
  TAssert.AssertEquals(2, Length(LIds));
  TAssert.AssertEquals('7', LIds[1]);
  Ok('');
  LIds := FEngine.Index('products').ListIds(F.Eq('category', 'bebida'));
  TAssert.AssertEquals(0, Length(LIds));
  TAssert.AssertEquals('GET /collections/products/documents/export?include_fields=id' +
    '&filter_by=category%3A%3D%60bebida%60', Req(2));
  try
    FEngine.Index('products').ListIds(F.Eq('title', 'x'));
    TAssert.Fail('A filter on a field not declared filterable must raise');
  except
    on ESearchRequestError do
      TAssert.AssertEquals('nothing sent', 3, FFake.RequestCount);
  end;
end;

procedure TTypesenseTests.SetSynonyms_PutsSetAndAttaches;
begin
  TAssert.AssertEquals('{"items":[{"id":"g0","synonyms":["tv","televisão"]},' +
    '{"id":"g1","root":"geladeira","synonyms":["refrigerador"]}]}',
    TypesenseSynonymSetJson([TSearchSynonym.Equivalent(['tv', 'televisão']),
      TSearchSynonym.OneWay('geladeira', ['refrigerador'])]));
  Ok('{"name":"products@1","synonym_sets":["mine"],"fields":[]}');
  Ok('{}');
  Ok('{}');
  FEngine.Index('products').SetSynonyms([TSearchSynonym.Equivalent(['tv', 'televisão'])]);
  TAssert.AssertEquals('GET /collections/products', Req(0));
  TAssert.AssertEquals('PUT /synonym_sets/products%401', Req(1));
  TAssert.AssertEquals('{"items":[{"id":"g0","synonyms":["tv","televisão"]}]}', FFake.Request(1).Body);
  TAssert.AssertEquals('PATCH /collections/products', Req(2));
  TAssert.AssertEquals('the application''s set kept', '{"synonym_sets":["mine","products@1"]}',
    FFake.Request(2).Body);
  Ok('{"name":"products@1","synonym_sets":["mine","products@1"],"fields":[]}');
  Ok('{}');
  FEngine.Index('products').SetSynonyms([]);
  TAssert.AssertEquals('{"items":[]}', FFake.Request(4).Body);
  TAssert.AssertEquals('attached already: no PATCH', 5, FFake.RequestCount);
  NoCollection;
  try
    FEngine.Index('products').SetSynonyms([]);
    TAssert.Fail('A missing collection must raise');
  except
    on ESearchIndexNotFound do
      TAssert.AssertEquals(6, FFake.RequestCount);
  end;
end;

procedure TTypesenseTests.SetCuration_PutsSet;
begin
  Ok('{"name":"products@1","fields":[]}');
  Ok('{}');
  Ok('{}');
  FEngine.SetCuration('products', [TTypesenseCuration.Create('pin', 'geladeira', ['4', '9'], ['3'])]);
  TAssert.AssertEquals('PUT /curation_sets/products%401', Req(1));
  TAssert.AssertEquals('{"items":[{"id":"pin","rule":{"query":"geladeira","match":"exact"},' +
    '"includes":[{"id":"4","position":1},{"id":"9","position":2}],"excludes":[{"id":"3"}]}]}',
    FFake.Request(1).Body);
  TAssert.AssertEquals('{"curation_sets":["products@1"]}', FFake.Request(2).Body);
  try
    FEngine.SetCuration('products', [TTypesenseCuration.Create('', 'x', [], [])]);
    TAssert.Fail('An item without an id must raise');
  except
    on ESearchArgumentError do
      TAssert.AssertEquals(3, FFake.RequestCount);
  end;
end;

procedure TTypesenseTests.Search_Highlight;
var
  R: ISearchResult;
  H: TSearchHighlight;
begin
  Collection;
  Ok('{"found":1,"hits":[{"document":{"id":"1"},"highlight":{"title":{"matched_tokens":["Café"],' +
    '"snippet":"x","value":"\u0001Café\u0002 com leite"}}}]}');
  R := FEngine.Index('products').Search('café').Fields(['id']).Highlight(['title']).Execute;
  TAssert.AssertEquals('GET /collections/products/documents/search?q=caf%C3%A9&query_by=title' +
    '&drop_tokens_threshold=0&page=1&per_page=20&include_fields=id&highlight_fields=title' +
    '&highlight_full_fields=title&highlight_start_tag=%01&highlight_end_tag=%02&enable_highlight_v1=false',
    Req(1));
  TAssert.AssertTrue(R.Hit(0).FindHighlight('title', H));
  TAssert.AssertEquals('Café com leite', H.Text);
  TAssert.AssertEquals('<mark>Café</mark> com leite', H.ToHtml);
  ExpectRequestError(FEngine.Index('products').Search('x').Highlight(['category']), 'category');
  TAssert.AssertEquals('nothing sent', 2, FFake.RequestCount);
end;

procedure TTypesenseTests.Schema_CacheExpires;
var
  LTime: TFakeTicker;
begin
  LTime := TFakeTicker.Create;
  TTicker.SetTicker(LTime);
  Collection;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('').Execute;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('').Execute;
  TAssert.AssertEquals('read once', 3, FFake.RequestCount);
  LTime.Advance(TYPESENSE_DEFAULT_CACHE_MS);
  Collection;
  Ok('{"found":0,"hits":[]}');
  FEngine.Index('products').Search('').Execute;
  TAssert.AssertEquals('read again', 'GET /collections/products', Req(3));
end;

initialization
  TDUnitX.RegisterTestFixture(TTypesenseTests);

end.
