unit PascalSearch.TypesenseIntegrationTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Integration/PascalSearch.TypesenseIntegrationTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ The Typesense adapter against a real Typesense (30.2 in Docker,
  tools/engines.sh): what the contract suite can't check because the mock has
  no transport, no TLS and no collections.

  - TLS through pascal-common-faa's client: the private CA accepted, the
    system store and a wrong host name refused, plain http to the TLS port
    an error.
  - A wrong key, a write to a collection never ensured, an import where one
    document is refused and the others kept (finding 5), the schema kept in
    the collection's metadata (read by another engine, changed in place,
    a kind change refused), a collection made without the library, the
    native access.

  Each test uses its own collections (it_*), dropped before and after.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Integration/fpc is
  generated from the master by tools/gen_fpc_mirror.py: edit only the
  master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Typesense,
  PascalSearch.IntegrationEnv;

type
  TTypesenseIntegrationTests = class(TTestCase)
  private
    FEngine: ITypesenseEngine;
    function TlsEngine(const AUrl, ACaFile: string): ITypesenseEngine;
    procedure ExpectUnavailable(const AEngine: ITypesenseEngine; const AWhat: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published

    procedure Tls_PrivateCa_Accepted;
    procedure Tls_SystemStore_Refused;
    procedure Tls_WrongHostName_Refused;
    procedure Tls_PlainHttpToTlsPort_Unavailable;

    procedure Auth_WrongKey;
    procedure Write_IndexNeverEnsured_NotFound;
    procedure Write_RefusedDocument_OthersKept;
    procedure Schema_ReadByAnotherEngine;
    procedure Schema_FlagsChange_InPlace;
    procedure Schema_KindChange_SchemaError;
    procedure Schema_NoTextFields;
    procedure Collection_MadeWithoutTheLibrary;
    procedure Native_Send;
  end;

implementation

const
  IDX = 'it_ts';
  NEVER = 'it_ts_never';
  FOREIGN = 'it_ts_foreign';

{ TTypesenseIntegrationTests }

procedure TTypesenseIntegrationTests.Setup;
begin
  FEngine := TTypesenseEngine.New(TsConfig);
  FEngine.DropIndex(IDX);
  FEngine.DropIndex(NEVER);
  FEngine.DropIndex(FOREIGN);
end;

procedure TTypesenseIntegrationTests.TearDown;
begin
  try
    if FEngine <> nil then
    begin
      FEngine.DropIndex(IDX);
      FEngine.DropIndex(NEVER);
      FEngine.DropIndex(FOREIGN);
    end;
  except
    // The next Setup drops them again.
  end;
  FEngine := nil;
end;

function TTypesenseIntegrationTests.TlsEngine(const AUrl, ACaFile: string): ITypesenseEngine;
var
  LConfig: TTypesenseConfig;
begin
  LConfig := TTypesenseConfig.Create(AUrl, TsKey);
  LConfig.TimeoutMs := 5000;
  LConfig.Http.Tls.CaFile := ACaFile;
  Result := TTypesenseEngine.New(LConfig);
end;

procedure TTypesenseIntegrationTests.ExpectUnavailable(const AEngine: ITypesenseEngine;
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

procedure TTypesenseIntegrationTests.Tls_PrivateCa_Accepted;
var
  LEngine: ITypesenseEngine;
begin
  TAssert.AssertTrue('the CA file (SEARCH_CA_FILE or .ci/it-certs/ca.pem)', CaFile <> '');
  LEngine := TlsEngine(TsTlsUrl, CaFile);
  TAssert.AssertFalse(LEngine.IndexExists(IDX));
  TAssert.AssertTrue(Pos('"version":"30.2"', LEngine.Send('GET', '/debug')) > 0);
end;

procedure TTypesenseIntegrationTests.Tls_SystemStore_Refused;
begin
  ExpectUnavailable(TlsEngine(TsTlsUrl, ''), 'a private CA against the system store');
end;

procedure TTypesenseIntegrationTests.Tls_WrongHostName_Refused;
begin
  ExpectUnavailable(TlsEngine(TsTlsWrongUrl, CaFile), 'a name the certificate doesn''t hold');
end;

procedure TTypesenseIntegrationTests.Tls_PlainHttpToTlsPort_Unavailable;
begin
  ExpectUnavailable(TlsEngine(TsTlsPlainUrl, ''), 'http to the TLS port');
end;

procedure TTypesenseIntegrationTests.Auth_WrongKey;
begin
  try
    TTypesenseEngine.New(TTypesenseConfig.Create(TsUrl, 'wrong-key')).IndexExists(IDX);
    TAssert.Fail('A wrong key must raise');
  except
    on E: ESearchAuthError do
      TAssert.AssertEquals(401, E.HttpStatus);
  end;
  try
    TTypesenseEngine.New(TTypesenseConfig.Create(TsUrl)).IndexExists(IDX);
    TAssert.Fail('No key must raise');
  except
    on E: ESearchAuthError do
      TAssert.AssertEquals(401, E.HttpStatus);
  end;
end;

procedure TTypesenseIntegrationTests.Write_IndexNeverEnsured_NotFound;
begin
  try
    FEngine.Index(NEVER).Upsert([TSearchDocument.New('1').Str('title', 'x')]);
    TAssert.Fail('A write to a collection never ensured must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertTrue(E.Message, Pos(NEVER, E.Message) > 0);
  end;
  TAssert.AssertFalse(FEngine.IndexExists(NEVER));
end;

procedure TTypesenseIntegrationTests.Write_RefusedDocument_OthersKept;
var
  LIndex: ISearchIndex;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title').Num('price', [sfFilter]));
  try
    LIndex.Upsert([TSearchDocument.New('good').Str('title', 'ok').Num('price', 1),
      TSearchDocument.New('bad').Str('title', 'no').Str('price', 'abc'),
      TSearchDocument.New('good2')]).WaitFor;
    TAssert.Fail('A refused document must fail the write');
  except
    on E: ESearchWriteFailed do
    begin
      TAssert.AssertFalse(E.WholeBatch);
      TAssert.AssertEquals(1, Length(E.Failures));
      TAssert.AssertEquals('bad', E.Failures[0].Id);
      TAssert.AssertEquals('400', E.Failures[0].Code);
    end;
  end;
  TAssert.AssertTrue('the others kept (finding 5)', LIndex.Get('good') <> nil);
  TAssert.AssertTrue(LIndex.Get('good2') <> nil);
  TAssert.AssertTrue(LIndex.Get('bad') = nil);
end;

procedure TTypesenseIntegrationTests.Schema_ReadByAnotherEngine;
var
  LOther: ISearchIndex;
  R: ISearchResult;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title').Keyword('category', [sfFacet])
    .Num('price', [sfSort]).WithMaxHits(2))
    .Upsert([TSearchDocument.New('1').Str('title', 'café').Str('category', 'b').Num('price', 3),
      TSearchDocument.New('2').Str('title', 'café com leite').Str('category', 'b').Num('price', 1),
      TSearchDocument.New('3').Str('title', 'chá').Str('category', 'c').Num('price', 2)]).WaitFor;
  // Another engine knows the schema only from the collection's metadata.
  LOther := TTypesenseEngine.New(TsConfig).Index(IDX);
  R := LOther.Search('').OrderBy('price').Facets(['category']).Page(1, 10).Execute;
  TAssert.AssertEquals(Int64(3), R.Total);
  TAssert.AssertEquals('MaxHits 2 from the metadata', 2, R.Count);
  TAssert.AssertEquals('2', R.Hit(0).Id);
  TAssert.AssertEquals('category', R.Facet(0).Field);
  TAssert.AssertEquals('Text fields searched', Int64(2), LOther.Search('cafe').Execute.Total);
  try
    LOther.Search('').Where(F.Eq('title', 'chá')).Execute;
    TAssert.Fail('title isn''t filterable');
  except
    on E: ESearchRequestError do
      TAssert.AssertTrue(E.Message, Pos('"title"', E.Message) > 0);
  end;
end;

procedure TTypesenseIntegrationTests.Schema_FlagsChange_InPlace;
var
  LIndex: ISearchIndex;
  LFacet: TSearchFacet;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title').Keyword('category', [sfFilter]));
  LIndex.Upsert([TSearchDocument.New('1').Str('title', 'a').Str('category', 'b'),
    TSearchDocument.New('2').Str('title', 'c').Str('category', 'b')]).WaitFor;
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title')
    .Keyword('category', [sfFilter, sfFacet]).Int('stock', [sfSort]));
  TAssert.AssertTrue(LIndex.Search('').Facets(['category']).Execute.FindFacet('category', LFacet));
  TAssert.AssertEquals('reindexed from the stored documents', 'b=2',
    LFacet.Values[0].Value + '=' + IntToStr(LFacet.Values[0].Count));
  TAssert.AssertEquals(Int64(2), LIndex.Search('').OrderBy('stock').Execute.Total);
end;

procedure TTypesenseIntegrationTests.Schema_KindChange_SchemaError;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Num('price', [sfFilter]));
  try
    FEngine.EnsureIndex(TSearchSchema.New(IDX).Keyword('price', [sfFilter]));
    TAssert.Fail('A kind change must raise');
  except
    on E: ESearchSchemaError do
      TAssert.AssertTrue(E.Message, Pos('"price"', E.Message) > 0);
  end;
end;

procedure TTypesenseIntegrationTests.Schema_NoTextFields;
var
  LIndex: ISearchIndex;
begin
  // As the mock and Meilisearch: words match nothing, an empty text all.
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Keyword('code', [sfFilter]));
  LIndex.Upsert([TSearchDocument.New('1').Str('code', 'abc')]).WaitFor;
  TAssert.AssertEquals(Int64(0), LIndex.Search('abc').Execute.Total);
  TAssert.AssertEquals(Int64(1), LIndex.Search('').Execute.Total);
  TAssert.AssertEquals(Int64(1), LIndex.Search('').Where(F.Eq('code', 'ABC')).Execute.Total);
end;

procedure TTypesenseIntegrationTests.Collection_MadeWithoutTheLibrary;
var
  LIndex: ISearchIndex;
begin
  FEngine.Send('POST', '/collections', '{"name":"' + FOREIGN + '","fields":[' +
    '{"name":"title","type":"string"},{"name":"tags","type":"string[]","facet":true}]}');
  FEngine.Send('POST', '/collections/' + FOREIGN + '/documents',
    '{"id":"1","title":"café","tags":["x"]}');
  LIndex := FEngine.Index(FOREIGN);
  TAssert.AssertEquals(Int64(1), LIndex.Search('cafe').Where(F.Eq('tags', 'x'))
    .Facets(['tags']).Execute.Total);
end;

procedure TTypesenseIntegrationTests.Native_Send;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  FEngine.Send('PUT', '/synonym_sets/it_ts_syn', '{"items":[{"id":"s1","synonyms":["leite","milk"]}]}');
  TAssert.AssertTrue(Pos('milk', FEngine.Send('GET', '/synonym_sets/it_ts_syn')) > 0);
  FEngine.Send('DELETE', '/synonym_sets/it_ts_syn');
  try
    FEngine.Send('GET', '/collections/' + NEVER);
    TAssert.Fail('A missing collection must raise');
  except
    on E: ESearchIndexNotFound do
      TAssert.AssertEquals(404, E.HttpStatus);
  end;
end;

initialization
  RegisterTest(TTypesenseIntegrationTests);

end.
