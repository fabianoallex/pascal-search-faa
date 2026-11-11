unit PascalSearch.TypesenseIntegrationTests;

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
  - 0.2.0 (design S25-S29): an index is an alias to its own collection;
    ReplaceIndex onto a collection made by 0.1.0; the synonym set deleted
    after its collection; a curation set pinning and hiding documents.

  Each test uses its own collections (it_*), dropped before and after.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalSearch.DUnitXCompat). The mirror in tests/Integration/fpc is
  generated from the master by tools/gen_fpc_mirror.py: edit only the
  master. }

interface

uses
  DUnitX.TestFramework,
  PascalSearch.DUnitXCompat,
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters,
  PascalSearch.Interfaces,
  PascalSearch.Typesense,
  PascalSearch.IntegrationEnv;

type
  [TestFixture]
  TTypesenseIntegrationTests = class
  private
    FEngine: ITypesenseEngine;
    function TlsEngine(const AUrl, ACaFile: string): ITypesenseEngine;
    procedure ExpectUnavailable(const AEngine: ITypesenseEngine; const AWhat: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Tls_PrivateCa_Accepted;
    [Test] procedure Tls_SystemStore_Refused;
    [Test] procedure Tls_WrongHostName_Refused;
    [Test] procedure Tls_PlainHttpToTlsPort_Unavailable;

    [Test] procedure Auth_WrongKey;
    [Test] procedure Write_IndexNeverEnsured_NotFound;
    [Test] procedure Write_RefusedDocument_OthersKept;
    [Test] procedure Schema_ReadByAnotherEngine;
    [Test] procedure Schema_FlagsChange_InPlace;
    [Test] procedure Schema_KindChange_SchemaError;
    [Test] procedure Schema_NoTextFields;
    [Test] procedure Collection_MadeWithoutTheLibrary;
    [Test] procedure Native_Send;
    [Test] procedure Index_IsAnAliasToItsCollection;
    [Test] procedure ReplaceIndex_OntoA010Collection;
    [Test] procedure Synonyms_SetDeletedWithTheIndex;
    [Test] procedure Curation_PinsAndHides;
  end;

implementation

const
  IDX = 'it_ts';
  NEVER = 'it_ts_never';
  FOREIGN = 'it_ts_foreign';
  STAGING = 'it_ts_new';

{ TTypesenseIntegrationTests }

procedure TTypesenseIntegrationTests.Setup;
begin
  FEngine := TTypesenseEngine.New(TsConfig);
  FEngine.DropIndex(IDX);
  FEngine.DropIndex(NEVER);
  FEngine.DropIndex(FOREIGN);
  FEngine.DropIndex(STAGING);
end;

procedure TTypesenseIntegrationTests.TearDown;
begin
  try
    if FEngine <> nil then
    begin
      FEngine.DropIndex(IDX);
      FEngine.DropIndex(NEVER);
      FEngine.DropIndex(FOREIGN);
      FEngine.DropIndex(STAGING);
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

// The member AMember of the JSON object AText, as JSON text.
function MemberJson(const AText, AMember: string): string;
var
  LJson, V: TJsonValue;
begin
  LJson := ParseJson(AText);
  try
    V := LJson.Find(AMember);
    if V = nil then
      Result := ''
    else if V.Kind = jkString then
      Result := V.AsString
    else
      Result := V.ToJson;
  finally
    LJson.Free;
  end;
end;

// The collection behind the alias AName.
function CollectionOf(const AEngine: ITypesenseEngine; const AName: string): string;
begin
  Result := MemberJson(AEngine.Send('GET', '/aliases/' + AName), 'collection_name');
end;

procedure TTypesenseIntegrationTests.Index_IsAnAliasToItsCollection;
var
  LCollection: string;
begin
  FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'))
    .Upsert([TSearchDocument.New('1').Str('title', 'café')]).WaitFor;
  LCollection := CollectionOf(FEngine, IDX);
  TAssert.AssertTrue(LCollection, Pos(IDX + '@', LCollection) = 1);
  TAssert.AssertEquals('1', MemberJson(FEngine.Send('GET', '/collections/' + IDX), 'num_documents'));
  FEngine.DropIndex(IDX);
  TAssert.AssertFalse(FEngine.IndexExists(IDX));
  try
    FEngine.Send('GET', '/collections/' + LCollection);
    TAssert.Fail('The collection must be gone');
  except
    on ESearchIndexNotFound do
      TAssert.AssertTrue(True);
  end;
  try
    FEngine.Send('GET', '/aliases/' + IDX);
    TAssert.Fail('The alias must be gone');
  except
    on ESearchError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseIntegrationTests.ReplaceIndex_OntoA010Collection;
var
  LSchema: ISearchSchema;
begin
  // What 0.1.0 made: a collection named like the index, no alias.
  LSchema := TSearchSchema.New(IDX).Text('title');
  FEngine.Send('POST', '/collections', TypesenseCollectionJson(LSchema));
  FEngine.Index(IDX).Upsert([TSearchDocument.New('old').Str('title', 'velho')]).WaitFor;
  TAssert.AssertEquals('old', FEngine.Index(IDX).Search('').Execute.Hit(0).Id);
  FEngine.EnsureIndex(SearchSchemaRenamed(LSchema, STAGING))
    .Upsert([TSearchDocument.New('new').Str('title', 'novo')]).WaitFor;
  FEngine.ReplaceIndex(IDX, STAGING);
  TAssert.AssertEquals('new', FEngine.Index(IDX).Search('').Execute.Hit(0).Id);
  TAssert.AssertEquals(Int64(1), FEngine.Index(IDX).Search('').Execute.Total);
  TAssert.AssertTrue('now an alias', Pos(STAGING + '@', CollectionOf(FEngine, IDX)) = 1);
  TAssert.AssertFalse(FEngine.IndexExists(STAGING));
  // A 0.1.0 collection can't be the source.
  FEngine.DropIndex(FOREIGN);
  FEngine.Send('POST', '/collections', TypesenseCollectionJson(TSearchSchema.New(FOREIGN).Text('title')));
  try
    FEngine.ReplaceIndex(IDX, FOREIGN);
    TAssert.Fail('A 0.1.0 source must raise');
  except
    on ESearchNotSupported do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseIntegrationTests.Synonyms_SetDeletedWithTheIndex;
var
  LIndex: ISearchIndex;
  LCollection: string;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  LIndex.Upsert([TSearchDocument.New('1').Str('title', 'televisão'),
    TSearchDocument.New('2').Str('title', 'geladeira')]).WaitFor;
  LIndex.SetSynonyms([TSearchSynonym.Equivalent(['tv', 'televisão'])]);
  TAssert.AssertEquals(Int64(1), LIndex.Search('tv').Execute.Total);
  LCollection := CollectionOf(FEngine, IDX);
  TAssert.AssertTrue(Pos('televisão', FEngine.Send('GET', '/synonym_sets/' + LCollection)) > 0);
  TAssert.AssertEquals('attached', '["' + LCollection + '"]',
    MemberJson(FEngine.Send('GET', '/collections/' + IDX), 'synonym_sets'));
  FEngine.DropIndex(IDX);
  try
    FEngine.Send('GET', '/synonym_sets/' + LCollection);
    TAssert.Fail('The set must be gone with the index');
  except
    on ESearchError do
      TAssert.AssertTrue(True);
  end;
end;

procedure TTypesenseIntegrationTests.Curation_PinsAndHides;
var
  LIndex: ISearchIndex;
  R: ISearchResult;
  I: Integer;
begin
  LIndex := FEngine.EnsureIndex(TSearchSchema.New(IDX).Text('title'));
  LIndex.Upsert([TSearchDocument.New('1').Str('title', 'geladeira'),
    TSearchDocument.New('2').Str('title', 'geladeira duplex'),
    TSearchDocument.New('3').Str('title', 'refrigerador')]).WaitFor;
  FEngine.SetCuration(IDX, [TTypesenseCuration.Create('pin', 'geladeira', ['3'], ['1'])]);
  R := LIndex.Search('geladeira').Execute;
  TAssert.AssertEquals('pinned first', '3', R.Hit(0).Id);
  for I := 0 to R.Count - 1 do
    TAssert.AssertTrue('hidden', R.Hit(I).Id <> '1');
  FEngine.SetCuration(IDX, []);
  TAssert.AssertEquals('cleared', Int64(2), LIndex.Search('geladeira').Execute.Total);
end;

initialization
  TDUnitX.RegisterTestFixture(TTypesenseIntegrationTests);

end.
