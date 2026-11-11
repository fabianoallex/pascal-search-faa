unit PascalSearch.Typesense;

{$I pascalsearch.inc}

(* The contract on Typesense (pinned and probed: 30.2), over pascal-common-faa's
   HTTP client (PascalCommon.Http, 1.31.0 or later), which verifies TLS on
   both compilers.

     Config := TTypesenseConfig.Create('https://search.local:8108', LKey);
     Config.Http.Tls.CaFile := 'ca.pem';      // a private CA; zeroed: the system store
     Engine := TTypesenseEngine.New(Config);

   Keep one engine per server and share it between threads: it owns one HTTP
   transport and its pool of kept-alive connections.

   How the contract maps (docs/design.md; "finding N" is
   docs/engine-findings.md):
   - An index is an alias to a collection (0.2.0, design S25): EnsureIndex
     of a new index creates the collection "<name>@<Unix ms>" and the alias
     <name>; every other call goes through the alias (finding 70).
     ReplaceIndex points the target's alias to the source's collection,
     deletes the source's alias and drops the target's old collection.
     Typesense has no rename or swap (findings 59, 60). A collection made by
     0.1.0 (named like the index, no alias) keeps working; replacing it
     drops it first, so searches answer ESearchIndexNotFound for a few
     milliseconds. DropIndex drops the collection, the alias and the
     library's synonym and curation sets.
   - The schema is stored in the collection's metadata ("pascal_search": the
     fields with their kinds and flags, and MaxHits). Typesense filters on
     any indexed field and searches only the query_by fields it is told
     (findings 18, 20), so the adapter needs the declaration: it refuses a
     filter, sort or facet on a field not declared for it (ESearchRequestError,
     as the mock and Meilisearch do) and searches the Text fields in order.
     The schema read from the server is kept CacheMs (60 s by default), so
     another process's ReplaceIndex is seen; EnsureIndex, DropIndex and
     ReplaceIndex update it. A collection made by something else (no metadata)
     is read from its fields: strings as Text, the rest by type, each indexed
     field filterable, facets and sorts as declared there.
   - Fields: Text and Keyword are "string", Keywords "string[]", Num
     "float", Int and Instant "int64", Bool "bool", all optional. A field
     with no flag other than Text's own, and every Stored field, isn't
     declared to Typesense: it is stored and returned, never indexed.
   - EnsureIndex creates the collection, or brings it up to the schema with
     one PATCH: new fields added, a field whose flags changed dropped and
     added again (Typesense reindexes it), the metadata replaced. A changed
     kind raises ESearchSchemaError.
   - Writes are synchronous (finding 4): an Upsert is an import with
     action=upsert, one JSON line per document; the answer says per line
     which were refused, and the others are kept (finding 5). WaitFor raises
     ESearchWriteFailed listing the refused ids (WholeBatch only when all
     were). Delete is a delete by filter on the ids (a missing id is not an
     error, finding 7), DeleteWhere a delete by the filter.
   - Search: q (* when blank), query_by the Text fields, drop_tokens_threshold
     0 (swAll) or 1 (swRelaxed), page/per_page, facet_by with
     max_facet_values 100 (as Meilisearch's default), include_fields with the
     id added. Typesense has no maxTotalHits: the adapter cuts hits past
     MaxHits itself. At most 3 sort keys (Typesense refuses more, 400).
   - Filters are written by TypesenseFilterText: every string in backticks;
     a value holding a backtick is refused (ESearchArgumentError), because
     nothing escapes it; AnyOf/NoneOf as ||/&& of single comparisons, never
     as a [...] list, where a backslash changes the parse (finding 22).
   - Highlight: highlight_fields and highlight_full_fields with #1/#2 as
     the tags (findings 63, 71), each field's "value" cut into parts; Text
     fields only (ESearchRequestError).
   - ListIds is one export with include_fields=id (finding 61).
   - SetSynonyms writes a synonym set named like the index's collection and
     attaches it (Typesense 30 keeps synonyms in global sets, finding 67);
     it moves with the collection on ReplaceIndex and is deleted only after
     the collection: a set deleted while attached breaks every search
     (finding 68).
   - Errors: 401/403 ESearchAuthError, 404 "Collection not found" (or "No
     collection with name ...", DELETE's) ESearchIndexNotFound, 5xx and no answer ESearchUnavailable, any other
     4xx ESearchRequestError, with Typesense's message in EngineMessage
     (Typesense sends no code, finding 37).

   Native access (S20, S29): ITypesenseEngine.Send for any endpoint, with
   the key and the error mapping applied, and SetCuration (a curation set
   named like the collection, attached like the synonyms). Typesense's typo
   settings are search parameters (finding 69): Raw. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalCommon.Http,
  PascalCommon.Http.Client,
  PascalSearch.Schema,
  PascalSearch.Filters,
  PascalSearch.Interfaces;

type
  TTypesenseConfig = record
    /// The server, http or https, without a path ('http://localhost:8108').
    Url: string;
    /// Sent as X-TYPESENSE-API-KEY; '' sends no key.
    ApiKey: string;
    /// Each request's deadline per wait (connect, read, write).
    /// 0 = the transport's default, 15 s.
    TimeoutMs: Integer;
    /// The HTTP transport: Http.Tls.CaFile for a private CA (PEM), CertFile/
    /// KeyFile/CertPassword for a client certificate, the pool's limits.
    /// Zeroed: https verified against the system store and the host name.
    /// Http.Tls.SkipServerVerification is INSECURE: for a lab only.
    Http: TPcHttpOptions;
    /// How long an index's schema read from the server is kept.
    /// 0 = TYPESENSE_DEFAULT_CACHE_MS.
    CacheMs: Integer;
    class function Create(const AUrl: string; const AApiKey: string = ''): TTypesenseConfig; static;
  end;

  /// A document a curation puts at a position (1 = first).
  TTypesenseCuratedHit = record
    Id: string;
    Position: Integer;
  end;

  /// One item of a curation set (finding 69): for the query AQuery
  /// ('exact' match, or 'contains'), the documents to put first, in order,
  /// and those to hide.
  TTypesenseCuration = record
    Id: string;
    Query: string;
    Match: string;
    Includes: TArray<TTypesenseCuratedHit>;
    Excludes: TArray<string>;
    /// AIncludeIds at positions 1, 2...; Match 'exact'.
    class function Create(const AId, AQuery: string; const AIncludeIds: array of string;
      const AExcludeIds: array of string): TTypesenseCuration; static;
  end;

  ITypesenseEngine = interface(ISearchEngine)
    ['{3D8E1B47-6C2A-4F95-B0E3-7A5C9D2F1E64}']
    function Config: TTypesenseConfig;
    /// One request to APath ('/synonym_sets/x'), with the key; returns the
    /// body of a 2xx answer, raises as the contract does for anything else.
    /// APath goes as written: encode its parts.
    function Send(const AMethod, APath: string; const ABody: string = ''): string;
    /// Replaces the index's curation (a curation set named like its
    /// collection, attached to it); an empty array clears it.
    procedure SetCuration(const AIndexName: string; const AItems: array of TTypesenseCuration);
  end;

  TTypesenseEngine = class(TInterfacedObject, ISearchEngine, ITypesenseEngine)
  private
    FConfig: TTypesenseConfig;
    FBase: string;
    FTransport: IPcHttpTransport;
    FLock: TCriticalSection;
    FSchemaNames: TArray<string>;
    FSchemas: TArray<ISearchSchema>;
    FSchemaAt: TArray<UInt64>;
    function Exchange(const AMethod, APath, ABody: string): TPcHttpResponse;
    procedure RaiseAnswer(const AMethod, APath: string; const AResponse: TPcHttpResponse);
    function Call(const AMethod, APath, ABody: string): string;
    function FindCollection(const AName: string): string;
    function CachedSchema(const AName: string): ISearchSchema;
    procedure CacheSchema(const AName: string; const ASchema: ISearchSchema);
    procedure ForgetSchema(const AName: string);
    function SchemaOf(const AName: string): ISearchSchema;
    function FindAlias(const AName: string): string;
    procedure DeleteQuietly(const APath: string);
    procedure PutSet(const AIndexName, AMember, AItemsJson: string);
  public
    /// Raises ESearchArgumentError for a URL that isn't http(s) or has a path.
    class function New(const AConfig: TTypesenseConfig): ITypesenseEngine; overload;
    /// With a transport of the caller's (tests: TPcFakeHttpTransport);
    /// AConfig.Http is then unused.
    class function New(const AConfig: TTypesenseConfig;
      const ATransport: IPcHttpTransport): ITypesenseEngine; overload;
    constructor Create(const AConfig: TTypesenseConfig; const ATransport: IPcHttpTransport);
    destructor Destroy; override;
    function Config: TTypesenseConfig;
    function Send(const AMethod, APath: string; const ABody: string = ''): string;
    function EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
    function Index(const AName: string): ISearchIndex;
    function IndexExists(const AName: string): Boolean;
    procedure DropIndex(const AName: string);
    procedure ReplaceIndex(const ATarget, ASource: string);
    procedure SetCuration(const AIndexName: string; const AItems: array of TTypesenseCuration);
  end;

const
  /// TTypesenseConfig.CacheMs = 0.
  TYPESENSE_DEFAULT_CACHE_MS = 60000;

/// The synonym set for AGroups as PUT /synonym_sets takes it: an
/// equivalent group as "synonyms", a one-way one with its "root"; ids g0,
/// g1...
function TypesenseSynonymSetJson(const AGroups: array of TSearchSynonym): string;

/// AFilter in Typesense's syntax: strings in backticks (one holding a
/// backtick raises ESearchArgumentError), numbers in plain decimal, instants
/// as Unix milliseconds, groups in parentheses; AnyOf/NoneOf as ||/&& of
/// single comparisons, Between as [low..high].
function TypesenseFilterText(const AFilter: ISearchFilter): string;

/// The collection for ASchema as POST /collections takes it: the name
/// (ACollection, or the schema's), the indexed fields and the library's
/// metadata.
function TypesenseCollectionJson(const ASchema: ISearchSchema; const ACollection: string = ''): string;

implementation

uses
  PascalCommon.Version,
  PascalCommon.Utf8,
  PascalCommon.SystemContext,
  PascalJsonMapper.Json,
  PascalSearch.Errors,
  PascalSearch.Values,
  PascalSearch.Documents,
  PascalSearch.Query,
  PascalSearch.EngineJson;

{$IF PASCALCOMMON_VERSION < 13100}
  {$MESSAGE FATAL 'pascal-search-faa needs pascal-common-faa 1.31.0 or later (PascalCommon.Http)'}
{$IFEND}

const
  ENGINE_NAME = 'Typesense';
  META_KEY = 'pascal_search';
  META_VERSION = 1;
  /// Ids per delete or fetch request (the ids go in the URL).
  IDS_PER_REQUEST = 100;
  MAX_FACET_VALUES = 100;
  COLLECTION_NOT_FOUND = 'Collection not found';

type
  TTypesenseIndex = class(TInterfacedObject, ISearchIndex, ISearchExecutor)
  private
    FEngineRef: ITypesenseEngine;
    FEngine: TTypesenseEngine;
    FName: string;
    FPath: string;
    procedure CheckFilterFields(const ASchema: ISearchSchema; const AFilter: ISearchFilter);
    function FetchIds(const AIds: TArray<string>): TJsonValue;
  public
    constructor Create(AEngine: TTypesenseEngine; const AName: string);
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

  /// Typesense applies a write before answering: the outcome is known.
  TTypesenseWrite = class(TInterfacedObject, ISearchWrite)
  private
    FFailures: TSearchFailures;
    FWholeBatch: Boolean;
  public
    constructor Create(const AFailures: TSearchFailures; AWholeBatch: Boolean);
    procedure WaitFor(ATimeoutMs: Integer = 0);
    function Pending: Boolean;
  end;

  TQueryParam = record
    Name: string;
    Value: string;
  end;

{ helpers }

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

function Backticked(const AValue: string): string;
begin
  if Pos('`', AValue) > 0 then
    raise ESearchArgumentError.CreateFmt('Typesense: a filter value can''t hold a backtick ' +
      '(nothing escapes it): "%s".', [AValue]);
  Result := '`' + AValue + '`';
end;

function FilterValue(const AValue: TSearchValue): string;
begin
  if AValue.Kind = svString then
    Result := Backticked(AValue.AsString)
  else
    Result := AValue.ToFilterText;
end;

function FilterJoin(const AFilter: ISearchFilter; const AOp, AJoin: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AFilter.ValueCount - 1 do
  begin
    if I > 0 then
      Result := Result + AJoin;
    Result := Result + AFilter.Field + AOp + FilterValue(AFilter.Value(I));
  end;
  if AFilter.ValueCount > 1 then
    Result := '(' + Result + ')';
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
    Result := Result + '(' + TypesenseFilterText(AFilter.Child(I)) + ')';
  end;
end;

function TypesenseFilterText(const AFilter: ISearchFilter): string;
var
  LField: string;
begin
  if AFilter = nil then
    Exit('');
  LField := AFilter.Field;
  case AFilter.Op of
    fopEq: Result := LField + ':=' + FilterValue(AFilter.Value(0));
    fopNotEq: Result := LField + ':!=' + FilterValue(AFilter.Value(0));
    fopAnyOf: Result := FilterJoin(AFilter, ':=', ' || ');
    fopNoneOf: Result := FilterJoin(AFilter, ':!=', ' && ');
    fopGt: Result := LField + ':>' + FilterValue(AFilter.Value(0));
    fopGe: Result := LField + ':>=' + FilterValue(AFilter.Value(0));
    fopLt: Result := LField + ':<' + FilterValue(AFilter.Value(0));
    fopLe: Result := LField + ':<=' + FilterValue(AFilter.Value(0));
    fopBetween: Result := LField + ':[' + FilterValue(AFilter.Value(0)) + '..' +
      FilterValue(AFilter.Value(1)) + ']';
    fopAll: Result := FilterGroup(AFilter, ' && ');
    fopAny: Result := FilterGroup(AFilter, ' || ');
  else
    raise ESearchNotSupported.CreateFmt('Typesense: no syntax for the filter "%s".',
      [SearchFilterOpName(AFilter.Op)]);
  end;
end;

function TypesenseType(AKind: TSearchFieldKind): string;
begin
  case AKind of
    skText, skKeyword: Result := 'string';
    skKeywords: Result := 'string[]';
    skNumber: Result := 'float';
    skInteger, skInstant: Result := 'int64';
    skBoolean: Result := 'bool';
  else
    Result := '';
  end;
end;

// Whether the field is declared to Typesense (indexed): Text fields, and
// fields with a flag. Stored fields and flagless ones are only stored.
function IsIndexed(const AField: TSearchField): Boolean;
begin
  Result := (AField.Kind <> skStored) and ((AField.Kind = skText) or (AField.Flags <> []));
end;

procedure WriteFieldDef(W: TJsonWriter; const AField: TSearchField);
begin
  W.BeginObject;
  W.Name('name');
  W.WriteString(AField.Name);
  W.Name('type');
  W.WriteString(TypesenseType(AField.Kind));
  W.Name('optional');
  W.WriteBoolean(True);
  W.Name('facet');
  W.WriteBoolean(AField.IsFacet);
  W.Name('sort');
  W.WriteBoolean(AField.IsSortable);
  W.EndObject;
end;

procedure WriteMetadata(W: TJsonWriter; const ASchema: ISearchSchema);
var
  I: Integer;
  LField: TSearchField;
begin
  W.Name('metadata');
  W.BeginObject;
  W.Name(META_KEY);
  W.BeginObject;
  W.Name('version');
  W.WriteInt64(META_VERSION);
  W.Name('max_hits');
  W.WriteInt64(ASchema.MaxHits);
  W.Name('fields');
  W.BeginArray;
  for I := 0 to ASchema.FieldCount - 1 do
  begin
    LField := ASchema.Field(I);
    W.BeginObject;
    W.Name('name');
    W.WriteString(LField.Name);
    W.Name('kind');
    W.WriteString(SearchFieldKindName(LField.Kind));
    W.Name('flags');
    W.BeginArray;
    if sfFilter in LField.Flags then
      W.WriteString('filter');
    if sfSort in LField.Flags then
      W.WriteString('sort');
    if sfFacet in LField.Flags then
      W.WriteString('facet');
    W.EndArray;
    W.EndObject;
  end;
  W.EndArray;
  W.EndObject;
  W.EndObject;
end;

function TypesenseCollectionJson(const ASchema: ISearchSchema; const ACollection: string): string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('name');
    if ACollection <> '' then
      W.WriteString(ACollection)
    else
      W.WriteString(ASchema.Name);
    W.Name('fields');
    W.BeginArray;
    for I := 0 to ASchema.FieldCount - 1 do
      if IsIndexed(ASchema.Field(I)) then
        WriteFieldDef(W, ASchema.Field(I));
    W.EndArray;
    WriteMetadata(W, ASchema);
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function AddFlags(const ASchema: ISearchSchema; AKind: TSearchFieldKind; const AName: string;
  AFlags: TSearchFieldFlags): ISearchSchema;
begin
  case AKind of
    skText: Result := ASchema.Text(AName, AFlags);
    skKeyword: Result := ASchema.Keyword(AName, AFlags);
    skKeywords: Result := ASchema.Keywords(AName, AFlags);
    skNumber: Result := ASchema.Num(AName, AFlags);
    skInteger: Result := ASchema.Int(AName, AFlags);
    skBoolean: Result := ASchema.Bool(AName, AFlags);
    skInstant: Result := ASchema.Instant(AName, AFlags);
  else
    Result := ASchema.Stored(AName);
  end;
end;

// The schema of a collection: from the library's metadata when there is
// one, otherwise from Typesense's own fields.
function SchemaFromCollection(const AName: string; ACollection: TJsonValue): ISearchSchema;
var
  LMeta, LFields, LField, LFlags: TJsonValue;
  LKind: TSearchFieldKind;
  LSet: TSearchFieldFlags;
  LType, LFieldName, LFlag: string;
  LMaxHits: Int64;
  I, J: Integer;
begin
  Result := TSearchSchema.New(AName);
  LMeta := SearchJsonMember(SearchJsonMember(ACollection, 'metadata'), META_KEY);
  if LMeta <> nil then
  begin
    if SearchJsonMember(LMeta, 'max_hits') <> nil then
      if SearchJsonMember(LMeta, 'max_hits').TryAsInt64(LMaxHits) and (LMaxHits > 0)
        and (LMaxHits <= MaxInt) then
        Result.WithMaxHits(Integer(LMaxHits));
    LFields := SearchJsonMember(LMeta, 'fields');
    if (LFields <> nil) and (LFields.Kind = jkArray) then
      for I := 0 to LFields.Count - 1 do
      begin
        LField := LFields.Items[I];
        LFieldName := SearchJsonText(LField, 'name');
        if not SearchFieldKindByName(SearchJsonText(LField, 'kind'), LKind) then
          raise ESearchSchemaError.CreateEngine(Format('%s: collection "%s": the metadata names an ' +
            'unknown field kind for "%s".', [ENGINE_NAME, AName, LFieldName]), 0, '', '');
        LSet := [];
        LFlags := SearchJsonMember(LField, 'flags');
        if (LFlags <> nil) and (LFlags.Kind = jkArray) then
          for J := 0 to LFlags.Count - 1 do
          begin
            LFlag := LFlags.Items[J].AsString;
            if LFlag = 'filter' then Include(LSet, sfFilter)
            else if LFlag = 'sort' then Include(LSet, sfSort)
            else if LFlag = 'facet' then Include(LSet, sfFacet);
          end;
        AddFlags(Result, LKind, LFieldName, LSet);
      end;
    Exit;
  end;
  // Made by something else: each indexed field filterable, strings searched.
  LFields := SearchJsonMember(ACollection, 'fields');
  if (LFields = nil) or (LFields.Kind <> jkArray) then
    Exit;
  for I := 0 to LFields.Count - 1 do
  begin
    LField := LFields.Items[I];
    LFieldName := SearchJsonText(LField, 'name');
    if (SearchJsonText(LField, 'index') = 'false') or not SearchIsValidFieldName(LFieldName)
      or (LFieldName = 'id') then
      Continue;
    LType := SearchJsonText(LField, 'type');
    LSet := [sfFilter];
    if SearchJsonText(LField, 'facet') = 'true' then
      Include(LSet, sfFacet);
    if (SearchJsonText(LField, 'sort') = 'true') and (LType <> 'string[]') then
      Include(LSet, sfSort);
    if LType = 'string' then LKind := skText
    else if LType = 'string[]' then LKind := skKeywords
    else if (LType = 'float') then LKind := skNumber
    else if (LType = 'int64') or (LType = 'int32') then LKind := skInteger
    else if LType = 'bool' then LKind := skBoolean
    else Continue;
    AddFlags(Result, LKind, LFieldName, LSet);
  end;
end;

function BoolText(AValue: Boolean): string;
begin
  if AValue then Result := 'true' else Result := 'false';
end;

function SameTypesenseField(AOld: TJsonValue; const ANew: TSearchField): Boolean;
begin
  Result := (SearchJsonText(AOld, 'type') = TypesenseType(ANew.Kind))
    and (SearchJsonText(AOld, 'facet') = BoolText(ANew.IsFacet))
    and (SearchJsonText(AOld, 'optional') = 'true')
    and (SearchJsonText(AOld, 'index') <> 'false');
  if Result and (ANew.Kind <> skKeywords) then
    Result := SearchJsonText(AOld, 'sort') = BoolText(ANew.IsSortable);
end;

function FindTypesenseField(ACollection: TJsonValue; const AName: string): TJsonValue;
var
  LFields: TJsonValue;
  I: Integer;
begin
  Result := nil;
  LFields := SearchJsonMember(ACollection, 'fields');
  if (LFields = nil) or (LFields.Kind <> jkArray) then
    Exit;
  for I := 0 to LFields.Count - 1 do
    if SearchJsonText(LFields.Items[I], 'name') = AName then
      Exit(LFields.Items[I]);
end;

// The PATCH that brings ACollection up to ASchema: fields added, a changed
// field dropped and added again, a field no longer indexed dropped, the
// metadata replaced.
function PatchJson(ACollection: TJsonValue; const ASchema: ISearchSchema): string;
var
  W, F: TJsonWriter;
  LField: TSearchField;
  LOld, LFields: TJsonValue;
  I: Integer;
  LAny: Boolean;

  procedure Drop(const AName: string);
  begin
    F.BeginObject;
    F.Name('name');
    F.WriteString(AName);
    F.Name('drop');
    F.WriteBoolean(True);
    F.EndObject;
    LAny := True;
  end;

begin
  LAny := False;
  F := TJsonWriter.Create;
  try
    F.BeginArray;
    for I := 0 to ASchema.FieldCount - 1 do
    begin
      LField := ASchema.Field(I);
      LOld := FindTypesenseField(ACollection, LField.Name);
      if IsIndexed(LField) then
      begin
        if (LOld <> nil) and SameTypesenseField(LOld, LField) then
          Continue;
        if LOld <> nil then
          Drop(LField.Name);
        WriteFieldDef(F, LField);
        LAny := True;
      end
      else if LOld <> nil then
        Drop(LField.Name);
    end;
    F.EndArray;
    W := TJsonWriter.Create;
    try
      W.BeginObject;
      if LAny then
      begin
        LFields := ParseJson(F.ToString);
        try
          W.Name('fields');
          W.WriteValue(LFields);
        finally
          LFields.Free;
        end;
      end;
      WriteMetadata(W, ASchema);
      W.EndObject;
      Result := W.ToString;
    finally
      W.Free;
    end;
  finally
    F.Free;
  end;
end;

function AliasJson(const ACollection: string): string;
var
  W: TJsonWriter;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('collection_name');
    W.WriteString(ACollection);
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function TypesenseSynonymSetJson(const AGroups: array of TSearchSynonym): string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('items');
    W.BeginArray;
    for I := 0 to High(AGroups) do
    begin
      W.BeginObject;
      W.Name('id');
      W.WriteString('g' + IntToStr(I));
      if AGroups[I].IsOneWay then
      begin
        W.Name('root');
        W.WriteString(AGroups[I].Root);
      end;
      SearchWriteStrings(W, 'synonyms', AGroups[I].Words);
      W.EndObject;
    end;
    W.EndArray;
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

function CurationSetJson(const AItems: array of TTypesenseCuration): string;
var
  W: TJsonWriter;
  I, J: Integer;
begin
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    W.Name('items');
    W.BeginArray;
    for I := 0 to High(AItems) do
    begin
      W.BeginObject;
      W.Name('id');
      W.WriteString(AItems[I].Id);
      W.Name('rule');
      W.BeginObject;
      W.Name('query');
      W.WriteString(AItems[I].Query);
      W.Name('match');
      if AItems[I].Match <> '' then
        W.WriteString(AItems[I].Match)
      else
        W.WriteString('exact');
      W.EndObject;
      if Length(AItems[I].Includes) > 0 then
      begin
        W.Name('includes');
        W.BeginArray;
        for J := 0 to High(AItems[I].Includes) do
        begin
          W.BeginObject;
          W.Name('id');
          W.WriteString(AItems[I].Includes[J].Id);
          W.Name('position');
          W.WriteInt64(AItems[I].Includes[J].Position);
          W.EndObject;
        end;
        W.EndArray;
      end;
      if Length(AItems[I].Excludes) > 0 then
      begin
        W.Name('excludes');
        W.BeginArray;
        for J := 0 to High(AItems[I].Excludes) do
        begin
          W.BeginObject;
          W.Name('id');
          W.WriteString(AItems[I].Excludes[J]);
          W.EndObject;
        end;
        W.EndArray;
      end;
      W.EndObject;
    end;
    W.EndArray;
    W.EndObject;
    Result := W.ToString;
  finally
    W.Free;
  end;
end;

{ TTypesenseCuration }

class function TTypesenseCuration.Create(const AId, AQuery: string; const AIncludeIds: array of string;
  const AExcludeIds: array of string): TTypesenseCuration;
var
  I: Integer;
begin
  Result := Default(TTypesenseCuration);
  Result.Id := AId;
  Result.Query := AQuery;
  Result.Match := 'exact';
  SetLength(Result.Includes, Length(AIncludeIds));
  for I := 0 to High(AIncludeIds) do
  begin
    Result.Includes[I].Id := AIncludeIds[I];
    Result.Includes[I].Position := I + 1;
  end;
  SetLength(Result.Excludes, Length(AExcludeIds));
  for I := 0 to High(AExcludeIds) do
    Result.Excludes[I] := AExcludeIds[I];
end;

{ TTypesenseConfig }

class function TTypesenseConfig.Create(const AUrl, AApiKey: string): TTypesenseConfig;
begin
  Result := Default(TTypesenseConfig);
  Result.Url := AUrl;
  Result.ApiKey := AApiKey;
end;

{ TTypesenseEngine }

class function TTypesenseEngine.New(const AConfig: TTypesenseConfig): ITypesenseEngine;
begin
  Result := New(AConfig, nil);
end;

class function TTypesenseEngine.New(const AConfig: TTypesenseConfig;
  const ATransport: IPcHttpTransport): ITypesenseEngine;
begin
  Result := TTypesenseEngine.Create(AConfig, ATransport);
end;

constructor TTypesenseEngine.Create(const AConfig: TTypesenseConfig;
  const ATransport: IPcHttpTransport);
var
  LUrl: TPcHttpUrl;
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
    FTransport := ATransport
  else
    FTransport := PcNewHttpTransport(AConfig.Http);
end;

destructor TTypesenseEngine.Destroy;
begin
  FTransport := nil;
  FLock.Free;
  inherited Destroy;
end;

function TTypesenseEngine.Config: TTypesenseConfig;
begin
  Result := FConfig;
end;

function TTypesenseEngine.Exchange(const AMethod, APath, ABody: string): TPcHttpResponse;
var
  LRequest: TPcHttpRequest;
begin
  LRequest := TPcHttpRequest.Create(AMethod, FBase + APath);
  LRequest.TimeoutMs := FConfig.TimeoutMs;
  if FConfig.ApiKey <> '' then
    LRequest.AddHeader('X-TYPESENSE-API-KEY', FConfig.ApiKey);
  if PcHttpMethodHasBody(AMethod) then
  begin
    LRequest.AddHeader('Content-Type', 'application/json');
    LRequest.Body := ABody;
  end;
  try
    Result := FTransport.Send(LRequest);
  except
    on E: EPcHttpTransport do
      raise ESearchUnavailable.CreateEngine(Format('%s: no answer: %s', [ENGINE_NAME, E.Message]), 0, '', '');
    on E: EPcTextEncoding do
      raise ESearchUnavailable.CreateEngine(Format('%s %s %s: the answer isn''t UTF-8 (%s).',
        [ENGINE_NAME, AMethod, PcUrlWithoutQuery(APath), E.Message]), 0, '', '');
    on E: EArgumentException do
      raise ESearchArgumentError.CreateFmt('%s %s %s: %s', [ENGINE_NAME, AMethod,
        PcUrlWithoutQuery(APath), E.Message]);
  end;
end;

procedure TTypesenseEngine.RaiseAnswer(const AMethod, APath: string;
  const AResponse: TPcHttpResponse);
var
  LJson: TJsonValue;
  LMessage, LText: string;
begin
  LMessage := '';
  try
    LJson := ParseJson(AResponse.Body);
    try
      LMessage := SearchJsonText(LJson, 'message');
    finally
      LJson.Free;
    end;
  except
    on EJsonError do
      LMessage := Copy(Trim(AResponse.Body), 1, 200);
  end;
  LText := Format('%s %s %s: HTTP %d', [ENGINE_NAME, AMethod, PcUrlWithoutQuery(APath), AResponse.Status]);
  if LMessage <> '' then
    LText := LText + ': ' + LMessage;
  case AResponse.Status of
    401, 403:
      raise ESearchAuthError.CreateEngine(LText, AResponse.Status, '', LMessage);
    404:
      // Search, get and writes say "Collection not found"; DELETE of the
      // collection itself "No collection with name `x` found." (measured).
      if (LMessage = COLLECTION_NOT_FOUND) or (Pos('No collection with name', LMessage) = 1) then
        raise ESearchIndexNotFound.CreateEngine(LText, AResponse.Status, '', LMessage)
      else
        raise ESearchRequestError.CreateEngine(LText, AResponse.Status, '', LMessage);
    400, 402, 405..499:
      raise ESearchRequestError.CreateEngine(LText, AResponse.Status, '', LMessage);
    500..599:
      raise ESearchUnavailable.CreateEngine(LText, AResponse.Status, '', LMessage);
  else
    raise ESearchError.CreateEngine(LText, AResponse.Status, '', LMessage);
  end;
end;

function TTypesenseEngine.Call(const AMethod, APath, ABody: string): string;
var
  LResponse: TPcHttpResponse;
begin
  LResponse := Exchange(AMethod, APath, ABody);
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer(AMethod, APath, LResponse);
  Result := LResponse.Body;
end;

function TTypesenseEngine.Send(const AMethod, APath, ABody: string): string;
begin
  Result := Call(AMethod, APath, ABody);
end;

// The collection's JSON text; '' when there is none.
function TTypesenseEngine.FindCollection(const AName: string): string;
var
  LPath: string;
  LResponse: TPcHttpResponse;
begin
  LPath := '/collections/' + Seg(AName);
  LResponse := Exchange('GET', LPath, '');
  if LResponse.Status = 404 then
  begin
    try
      RaiseAnswer('GET', LPath, LResponse);
    except
      on ESearchIndexNotFound do
        Exit('');
    end;
  end;
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer('GET', LPath, LResponse);
  Result := LResponse.Body;
end;

function TTypesenseEngine.CachedSchema(const AName: string): ISearchSchema;
var
  I, LLimit: Integer;
begin
  Result := nil;
  LLimit := FConfig.CacheMs;
  if LLimit <= 0 then
    LLimit := TYPESENSE_DEFAULT_CACHE_MS;
  FLock.Enter;
  try
    for I := 0 to High(FSchemaNames) do
      if (FSchemaNames[I] = AName) and (TTicker.ElapsedMs(FSchemaAt[I]) < UInt64(LLimit)) then
        Exit(FSchemas[I]);
  finally
    FLock.Leave;
  end;
end;

procedure TTypesenseEngine.CacheSchema(const AName: string; const ASchema: ISearchSchema);
var
  I, N: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FSchemaNames) do
      if FSchemaNames[I] = AName then
      begin
        FSchemas[I] := ASchema;
        FSchemaAt[I] := TTicker.NowMs;
        Exit;
      end;
    N := Length(FSchemaNames);
    SetLength(FSchemaNames, N + 1);
    SetLength(FSchemas, N + 1);
    SetLength(FSchemaAt, N + 1);
    FSchemaNames[N] := AName;
    FSchemas[N] := ASchema;
    FSchemaAt[N] := TTicker.NowMs;
  finally
    FLock.Leave;
  end;
end;

procedure TTypesenseEngine.ForgetSchema(const AName: string);
var
  I, J: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FSchemaNames) do
      if FSchemaNames[I] = AName then
      begin
        for J := I to High(FSchemaNames) - 1 do
        begin
          FSchemaNames[J] := FSchemaNames[J + 1];
          FSchemas[J] := FSchemas[J + 1];
          FSchemaAt[J] := FSchemaAt[J + 1];
        end;
        SetLength(FSchemaNames, Length(FSchemaNames) - 1);
        SetLength(FSchemas, Length(FSchemas) - 1);
        SetLength(FSchemaAt, Length(FSchemaAt) - 1);
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

function TTypesenseEngine.SchemaOf(const AName: string): ISearchSchema;
var
  LText: string;
  LJson: TJsonValue;
begin
  Result := CachedSchema(AName);
  if Result <> nil then
    Exit;
  LText := FindCollection(AName);
  if LText = '' then
    raise ESearchIndexNotFound.CreateEngine(Format('%s: collection "%s" not found; EnsureIndex it first.',
      [ENGINE_NAME, AName]), 404, '', COLLECTION_NOT_FOUND);
  LJson := ParseBody(LText, 'GET /collections/' + AName);
  try
    Result := SchemaFromCollection(AName, LJson);
  finally
    LJson.Free;
  end;
  CacheSchema(AName, Result);
end;

function TTypesenseEngine.EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
var
  LText, LBody, LPath, LCollection, LStamp: string;
  LJson: TJsonValue;
  LOld: ISearchSchema;
  LOldField: TSearchField;
  I: Integer;
  LResponse: TPcHttpResponse;
begin
  if ASchema = nil then
    raise ESearchArgumentError.Create('EnsureIndex: the schema is nil.');
  LPath := '/collections/' + Seg(ASchema.Name);
  LText := FindCollection(ASchema.Name);
  if LText = '' then
  begin
    // A new collection behind the alias (design S25); a name taken (409)
    // gets a suffix.
    LStamp := ASchema.Name + '@' + IntToStr(SearchInstantToMs(TClock.Now));
    LCollection := LStamp;
    for I := 2 to 10 do
    begin
      LResponse := Exchange('POST', '/collections', TypesenseCollectionJson(ASchema, LCollection));
      if LResponse.Status <> 409 then
        Break;
      LCollection := LStamp + '_' + IntToStr(I);
    end;
    if not IsSuccess(LResponse.Status) then
      RaiseAnswer('POST', '/collections', LResponse);
    Call('PUT', '/aliases/' + Seg(ASchema.Name), AliasJson(LCollection));
    CacheSchema(ASchema.Name, ASchema);
    Exit(TTypesenseIndex.Create(Self, ASchema.Name));
  end;
  LJson := ParseBody(LText, 'GET ' + LPath);
  try
    LOld := SchemaFromCollection(ASchema.Name, LJson);
    for I := 0 to ASchema.FieldCount - 1 do
      if LOld.FindField(ASchema.Field(I).Name, LOldField)
        and (LOldField.Kind <> ASchema.Field(I).Kind) then
        raise ESearchSchemaError.CreateEngine(Format('Index "%s": field "%s" is %s and can''t become %s ' +
          'in place; drop and rebuild the index.', [ASchema.Name, LOldField.Name,
          SearchFieldKindName(LOldField.Kind), SearchFieldKindName(ASchema.Field(I).Kind)]), 0, '', '');
    LBody := PatchJson(LJson, ASchema);
  finally
    LJson.Free;
  end;
  Call('PATCH', LPath, LBody);
  CacheSchema(ASchema.Name, ASchema);
  Result := TTypesenseIndex.Create(Self, ASchema.Name);
end;

function TTypesenseEngine.Index(const AName: string): ISearchIndex;
begin
  SearchCheckIndexName(AName);
  Result := TTypesenseIndex.Create(Self, AName);
end;

function TTypesenseEngine.IndexExists(const AName: string): Boolean;
begin
  SearchCheckIndexName(AName);
  Result := FindCollection(AName) <> '';
end;

// The collection the alias AName points to; '' when there is no such alias.
function TTypesenseEngine.FindAlias(const AName: string): string;
var
  LPath: string;
  LResponse: TPcHttpResponse;
  LJson: TJsonValue;
begin
  LPath := '/aliases/' + Seg(AName);
  LResponse := Exchange('GET', LPath, '');
  if LResponse.Status = 404 then
    Exit('');
  if not IsSuccess(LResponse.Status) then
    RaiseAnswer('GET', LPath, LResponse);
  LJson := ParseBody(LResponse.Body, 'GET ' + LPath);
  try
    Result := SearchJsonText(LJson, 'collection_name');
  finally
    LJson.Free;
  end;
end;

// A DELETE for which 404 (already gone) is no error.
procedure TTypesenseEngine.DeleteQuietly(const APath: string);
var
  LResponse: TPcHttpResponse;
begin
  LResponse := Exchange('DELETE', APath, '');
  if (LResponse.Status <> 404) and not IsSuccess(LResponse.Status) then
    RaiseAnswer('DELETE', APath, LResponse);
end;

// Writes the set AMember ('synonym_sets', 'curation_sets') named like the
// index's collection, and attaches it, keeping the sets already attached.
procedure TTypesenseEngine.PutSet(const AIndexName, AMember, AItemsJson: string);
var
  LText, LCollection: string;
  LJson, LSets: TJsonValue;
  LNames: TArray<string>;
  W: TJsonWriter;
  I: Integer;
  LAttached: Boolean;
begin
  SearchCheckIndexName(AIndexName);
  LText := FindCollection(AIndexName);
  if LText = '' then
    raise ESearchIndexNotFound.CreateEngine(Format('%s: collection "%s" not found; EnsureIndex it first.',
      [ENGINE_NAME, AIndexName]), 404, '', COLLECTION_NOT_FOUND);
  LJson := ParseBody(LText, 'GET /collections/' + AIndexName);
  try
    LCollection := SearchJsonText(LJson, 'name');
    if LCollection = '' then
      LCollection := AIndexName;
    LNames := nil;
    LAttached := False;
    LSets := SearchJsonMember(LJson, AMember);
    if (LSets <> nil) and (LSets.Kind = jkArray) then
      for I := 0 to LSets.Count - 1 do
        if LSets.Items[I].Kind = jkString then
        begin
          SetLength(LNames, Length(LNames) + 1);
          LNames[High(LNames)] := LSets.Items[I].AsString;
          if LNames[High(LNames)] = LCollection then
            LAttached := True;
        end;
  finally
    LJson.Free;
  end;
  Call('PUT', '/' + AMember + '/' + Seg(LCollection), AItemsJson);
  if LAttached then
    Exit;
  SetLength(LNames, Length(LNames) + 1);
  LNames[High(LNames)] := LCollection;
  W := TJsonWriter.Create;
  try
    W.BeginObject;
    SearchWriteStrings(W, AMember, LNames);
    W.EndObject;
    Call('PATCH', '/collections/' + Seg(AIndexName), W.ToString);
  finally
    W.Free;
  end;
end;

procedure TTypesenseEngine.SetCuration(const AIndexName: string; const AItems: array of TTypesenseCuration);
var
  I: Integer;
begin
  for I := 0 to High(AItems) do
    if (AItems[I].Id = '') or (AItems[I].Query = '') then
      raise ESearchArgumentError.CreateFmt('SetCuration: item %d needs an id and a query.', [I]);
  PutSet(AIndexName, 'curation_sets', CurationSetJson(AItems));
end;

procedure TTypesenseEngine.DropIndex(const AName: string);
var
  LCollection: string;
begin
  SearchCheckIndexName(AName);
  ForgetSchema(AName);
  LCollection := FindAlias(AName);
  if LCollection <> '' then
  begin
    DeleteQuietly('/collections/' + Seg(LCollection));
    DeleteQuietly('/aliases/' + Seg(AName));
  end
  else
  begin
    // A collection made by 0.1.0, named like the index.
    LCollection := AName;
    DeleteQuietly('/collections/' + Seg(AName));
  end;
  // The library's sets, only once their collection is gone (finding 68).
  DeleteQuietly('/synonym_sets/' + Seg(LCollection));
  DeleteQuietly('/curation_sets/' + Seg(LCollection));
end;

procedure TTypesenseEngine.ReplaceIndex(const ATarget, ASource: string);
var
  LSource, LOld: string;
  LOldIsCollection: Boolean;
begin
  SearchCheckIndexName(ATarget);
  SearchCheckIndexName(ASource);
  if ATarget = ASource then
    raise ESearchArgumentError.CreateFmt('ReplaceIndex: "%s" can''t replace itself.', [ATarget]);
  LSource := FindAlias(ASource);
  if LSource = '' then
  begin
    if FindCollection(ASource) <> '' then
      raise ESearchNotSupported.CreateFmt('%s: index "%s" is a collection made before 0.2.0, without an ' +
        'alias; it can''t move under another name. Ensure the new index with 0.2.0.', [ENGINE_NAME, ASource]);
    raise ESearchIndexNotFound.CreateEngine(Format('%s: index "%s" not found.', [ENGINE_NAME, ASource]),
      404, '', COLLECTION_NOT_FOUND);
  end;
  if FindCollection(ASource) = '' then
    raise ESearchIndexNotFound.CreateEngine(Format('%s: index "%s" points to the missing collection "%s".',
      [ENGINE_NAME, ASource, LSource]), 404, '', COLLECTION_NOT_FOUND);
  LOld := FindAlias(ATarget);
  LOldIsCollection := (LOld = '') and (FindCollection(ATarget) <> '');
  ForgetSchema(ATarget);
  ForgetSchema(ASource);
  if LOldIsCollection then
  begin
    // A 0.1.0 collection holds the name: an alias can't be made while it
    // exists (finding 60), so searches miss the index until the PUT below.
    LOld := ATarget;
    DeleteQuietly('/collections/' + Seg(ATarget));
  end;
  Call('PUT', '/aliases/' + Seg(ATarget), AliasJson(LSource));
  DeleteQuietly('/aliases/' + Seg(ASource));
  if (LOld <> '') and (LOld <> LSource) then
  begin
    if not LOldIsCollection then
      DeleteQuietly('/collections/' + Seg(LOld));
    DeleteQuietly('/synonym_sets/' + Seg(LOld));
    DeleteQuietly('/curation_sets/' + Seg(LOld));
  end;
end;


{ TTypesenseIndex }

constructor TTypesenseIndex.Create(AEngine: TTypesenseEngine; const AName: string);
begin
  inherited Create;
  FEngine := AEngine;
  FEngineRef := AEngine;
  FName := AName;
  FPath := '/collections/' + Seg(AName);
end;

function TTypesenseIndex.Name: string;
begin
  Result := FName;
end;

procedure TTypesenseIndex.CheckFilterFields(const ASchema: ISearchSchema; const AFilter: ISearchFilter);
var
  LField: TSearchField;
  I: Integer;
begin
  if AFilter.Op in [fopAll, fopAny] then
  begin
    for I := 0 to AFilter.ChildCount - 1 do
      CheckFilterFields(ASchema, AFilter.Child(I));
    Exit;
  end;
  if AFilter.Field = 'id' then
    Exit;
  if not ASchema.FindField(AFilter.Field, LField) or not LField.IsFilterable then
    raise ESearchRequestError.CreateEngine(Format('Field "%s" is not filterable in index "%s".',
      [AFilter.Field, FName]), 0, '', '');
end;

function TTypesenseIndex.Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
var
  LBody, LLine, LError: string;
  LFailures: TSearchFailures;
  LJson: TJsonValue;
  I, P, N: Integer;
begin
  for I := 0 to High(ADocs) do
    if ADocs[I] = nil then
      raise ESearchArgumentError.CreateFmt('Upsert: document %d is nil.', [I]);
  FEngine.SchemaOf(FName);
  LFailures := nil;
  if Length(ADocs) = 0 then
    Exit(TTypesenseWrite.Create(nil, False));
  LBody := '';
  for I := 0 to High(ADocs) do
  begin
    if I > 0 then
      LBody := LBody + #10;
    LBody := LBody + ADocs[I].ToJson;
  end;
  LBody := FEngine.Call('POST', FPath + '/documents/import?action=upsert', LBody);
  // One JSON object per line, in the order sent.
  N := 0;
  I := 0;
  while LBody <> '' do
  begin
    P := Pos(#10, LBody);
    if P = 0 then
    begin
      LLine := LBody;
      LBody := '';
    end
    else
    begin
      LLine := Copy(LBody, 1, P - 1);
      System.Delete(LBody, 1, P);
    end;
    LLine := Trim(LLine);
    if LLine = '' then
      Continue;
    LJson := ParseBody(LLine, 'POST import');
    try
      if (SearchJsonText(LJson, 'success') <> 'true') and (I <= High(ADocs)) then
      begin
        LError := SearchJsonText(LJson, 'error');
        SetLength(LFailures, N + 1);
        LFailures[N] := TSearchFailure.Create(ADocs[I].Id, SearchJsonText(LJson, 'code'), LError);
        Inc(N);
      end;
    finally
      LJson.Free;
    end;
    Inc(I);
  end;
  if I < Length(ADocs) then
    raise ESearchUnavailable.CreateEngine(Format('%s POST %s/documents/import: %d answers for %d documents.',
      [ENGINE_NAME, FPath, I, Length(ADocs)]), 0, '', '');
  Result := TTypesenseWrite.Create(LFailures, N = Length(ADocs));
end;

function IdListFilter(const AIds: TArray<string>; AFrom, ATo: Integer): string;
var
  I: Integer;
begin
  // Ids are [A-Za-z0-9_-] (checked): a list of them is safe (finding 22).
  Result := 'id:[';
  for I := AFrom to ATo do
  begin
    if I > AFrom then
      Result := Result + ',';
    Result := Result + '`' + AIds[I] + '`';
  end;
  Result := Result + ']';
end;

function TTypesenseIndex.Delete(const AIds: array of string): ISearchWrite;
var
  LIds: TArray<string>;
  I, LFrom, LTo: Integer;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  FEngine.SchemaOf(FName);
  LIds := nil;
  SetLength(LIds, Length(AIds));
  for I := 0 to High(AIds) do
    LIds[I] := AIds[I];
  LFrom := 0;
  while LFrom <= High(LIds) do
  begin
    LTo := LFrom + IDS_PER_REQUEST - 1;
    if LTo > High(LIds) then
      LTo := High(LIds);
    FEngine.Call('DELETE', FPath + '/documents?filter_by=' + Seg(IdListFilter(LIds, LFrom, LTo)), '');
    LFrom := LTo + 1;
  end;
  Result := TTypesenseWrite.Create(nil, False);
end;

function TTypesenseIndex.DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
var
  LText: string;
begin
  if AFilter = nil then
    raise ESearchArgumentError.Create('DeleteWhere: the filter is nil.');
  LText := TypesenseFilterText(AFilter);
  CheckFilterFields(FEngine.SchemaOf(FName), AFilter);
  FEngine.Call('DELETE', FPath + '/documents?filter_by=' + Seg(LText), '');
  Result := TTypesenseWrite.Create(nil, False);
end;

function TTypesenseIndex.Get(const AId: string): ISearchHit;
var
  LPath: string;
  LResponse: TPcHttpResponse;
begin
  SearchCheckId(AId);
  LPath := FPath + '/documents/' + Seg(AId);
  LResponse := FEngine.Exchange('GET', LPath, '');
  if LResponse.Status = 404 then
  begin
    // A missing document is nil; a missing collection raises.
    try
      FEngine.RaiseAnswer('GET', LPath, LResponse);
    except
      on ESearchRequestError do
        Exit(nil);
    end;
  end;
  if not IsSuccess(LResponse.Status) then
    FEngine.RaiseAnswer('GET', LPath, LResponse);
  Result := TSearchHit.Create(AId, ParseBody(LResponse.Body, 'GET ' + LPath));
end;

// The documents of AIds (at most IDS_PER_REQUEST), as a search answer.
function TTypesenseIndex.FetchIds(const AIds: TArray<string>): TJsonValue;
begin
  Result := ParseBody(FEngine.Call('GET', FPath + '/documents/search?q=*&filter_by=' +
    Seg(IdListFilter(AIds, 0, High(AIds))) + '&per_page=' + IntToStr(Length(AIds)), ''),
    'GET ' + FPath + '/documents/search');
end;

function TTypesenseIndex.GetMany(const AIds: array of string): ISearchHits;
var
  LList: TSearchHitList;
  LWanted, LChunk: TArray<string>;
  LAnswers: TArray<TJsonValue>;
  LHits, LDoc: TJsonValue;
  I, J, K, LFrom: Integer;
  LKnown, LFound: Boolean;
begin
  for I := 0 to High(AIds) do
    SearchCheckId(AIds[I]);
  LList := TSearchHitList.Create;
  Result := LList;
  FEngine.SchemaOf(FName);
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
  LAnswers := nil;
  try
    LFrom := 0;
    while LFrom <= High(LWanted) do
    begin
      LChunk := Copy(LWanted, LFrom, IDS_PER_REQUEST);
      SetLength(LAnswers, Length(LAnswers) + 1);
      LAnswers[High(LAnswers)] := FetchIds(LChunk);
      Inc(LFrom, IDS_PER_REQUEST);
    end;
    for I := 0 to High(AIds) do
    begin
      LFound := False;
      for K := 0 to High(LAnswers) do
      begin
        LHits := SearchJsonMember(LAnswers[K], 'hits');
        if (LHits = nil) or (LHits.Kind <> jkArray) then
          Continue;
        for J := 0 to LHits.Count - 1 do
        begin
          LDoc := SearchJsonMember(LHits.Items[J], 'document');
          if (LDoc <> nil) and (SearchJsonId(SearchJsonMember(LDoc, 'id')) = AIds[I]) then
          begin
            LList.AddHit(AIds[I], SearchCloneJson(LDoc));
            LFound := True;
            Break;
          end;
        end;
        if LFound then
          Break;
      end;
    end;
  finally
    for K := 0 to High(LAnswers) do
      LAnswers[K].Free;
  end;
end;

function TTypesenseIndex.Search(const AText: string): ISearchQuery;
begin
  Result := TSearchQuery.Create(Self, AText);
end;

function TTypesenseIndex.ListIds(const AFilter: ISearchFilter): TArray<string>;
var
  LUrl, LBody, LLine, LText: string;
  LJson: TJsonValue;
  P, N: Integer;
begin
  LText := '';
  if AFilter <> nil then
    LText := TypesenseFilterText(AFilter);
  LBody := '';
  if AFilter <> nil then
    CheckFilterFields(FEngine.SchemaOf(FName), AFilter)
  else
    FEngine.SchemaOf(FName);
  LUrl := FPath + '/documents/export?include_fields=id';
  if LText <> '' then
    LUrl := LUrl + '&filter_by=' + Seg(LText);
  LBody := FEngine.Call('GET', LUrl, '');
  // One JSON object per line.
  Result := nil;
  N := 0;
  while LBody <> '' do
  begin
    P := Pos(#10, LBody);
    if P = 0 then
    begin
      LLine := LBody;
      LBody := '';
    end
    else
    begin
      LLine := Copy(LBody, 1, P - 1);
      System.Delete(LBody, 1, P);
    end;
    LLine := Trim(LLine);
    if LLine = '' then
      Continue;
    LJson := ParseBody(LLine, 'GET ' + FPath + '/documents/export');
    try
      if N >= Length(Result) then
        SetLength(Result, N * 2 + 16);
      Result[N] := SearchJsonId(SearchJsonMember(LJson, 'id'));
      Inc(N);
    finally
      LJson.Free;
    end;
  end;
  SetLength(Result, N);
end;

procedure TTypesenseIndex.SetSynonyms(const AGroups: array of TSearchSynonym);
begin
  SearchCheckSynonyms(AGroups);
  FEngine.PutSet(FName, 'synonym_sets', TypesenseSynonymSetJson(AGroups));
end;

function TTypesenseIndex.ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
var
  LSchema: ISearchSchema;
  LField: TSearchField;
  LParams: TArray<TQueryParam>;
  LText, LQueryBy, LList, LUrl, LAnswer, LWhat: string;
  LRaw: TJsonValue;
  LJson, LHits, LDoc, LFacets, LFacet, LCounts, LMarks, V: TJsonValue;
  LResult: TSearchResult;
  LOutHit: TSearchHit;
  LHighlight: TSearchHighlight;
  LTotal, LStart: Int64;
  LOut: TSearchFacet;
  I, J, K: Integer;
  LHasId: Boolean;

  // A Raw parameter of the same name replaces the library's.
  procedure Put(const AName, AValue: string);
  var
    X: Integer;
  begin
    for X := 0 to High(ARequest.Raw) do
      if ARequest.Raw[X].Name = AName then
        Exit;
    SetLength(LParams, Length(LParams) + 1);
    LParams[High(LParams)].Name := AName;
    LParams[High(LParams)].Value := AValue;
  end;

  function NoTextResult: ISearchResult;
  var
    X: Integer;
    LEmpty: TSearchFacet;
    R: TSearchResult;
  begin
    R := TSearchResult.Create(0, ARequest.Page, ARequest.PageSize, '');
    Result := R;
    for X := 0 to High(ARequest.Facets) do
    begin
      LEmpty := Default(TSearchFacet);
      LEmpty.Field := ARequest.Facets[X];
      R.AddFacet(LEmpty);
    end;
  end;

begin
  LSchema := FEngine.SchemaOf(FName);

  // The schema's checks, as the mock and Meilisearch make them.
  if ARequest.Filter <> nil then
    CheckFilterFields(LSchema, ARequest.Filter);
  for I := 0 to High(ARequest.Sorts) do
    if not LSchema.FindField(ARequest.Sorts[I].Field, LField) or not LField.IsSortable then
      raise ESearchRequestError.CreateEngine(Format('Field "%s" is not sortable in index "%s".',
        [ARequest.Sorts[I].Field, FName]), 0, '', '');
  for I := 0 to High(ARequest.Facets) do
    if not LSchema.FindField(ARequest.Facets[I], LField) or not LField.IsFacet then
      raise ESearchRequestError.CreateEngine(Format('Field "%s" is not a facet in index "%s".',
        [ARequest.Facets[I], FName]), 0, '', '');
  for I := 0 to High(ARequest.Highlight) do
    if not LSchema.FindField(ARequest.Highlight[I], LField) or not LField.IsSearchable then
      raise ESearchRequestError.CreateEngine(Format('Field "%s" is not a Text field in index "%s": ' +
        'it can''t be highlighted.', [ARequest.Highlight[I], FName]), 0, '', '');
  if (ARequest.PageSize > 0) and (Int64(ARequest.Page - 1) * ARequest.PageSize >= LSchema.MaxHits) then
    raise ESearchArgumentError.CreateFmt('Page %d of %d starts past the index''s MaxHits (%d).',
      [ARequest.Page, ARequest.PageSize, LSchema.MaxHits]);

  LText := Trim(ARequest.TextToSend);
  LQueryBy := '';
  for I := 0 to LSchema.FieldCount - 1 do
    if LSchema.Field(I).IsSearchable then
    begin
      if LQueryBy <> '' then
        LQueryBy := LQueryBy + ',';
      LQueryBy := LQueryBy + LSchema.Field(I).Name;
    end;
  // Words and nothing to search them in: no document matches (the mock's
  // behavior; Typesense would refuse a query without query_by).
  if (LText <> '') and (LQueryBy = '') and (Length(ARequest.Raw) = 0) then
    Exit(NoTextResult);

  LParams := nil;
  if LText = '' then
    Put('q', '*')
  else
  begin
    Put('q', LText);
    Put('query_by', LQueryBy);
  end;
  if ARequest.Words = swRelaxed then
    Put('drop_tokens_threshold', '1')
  else
    Put('drop_tokens_threshold', '0');
  if ARequest.Filter <> nil then
    Put('filter_by', TypesenseFilterText(ARequest.Filter));
  if Length(ARequest.Sorts) > 0 then
  begin
    LList := '';
    for I := 0 to High(ARequest.Sorts) do
    begin
      if I > 0 then
        LList := LList + ',';
      if ARequest.Sorts[I].Order = soDesc then
        LList := LList + ARequest.Sorts[I].Field + ':desc'
      else
        LList := LList + ARequest.Sorts[I].Field + ':asc';
    end;
    Put('sort_by', LList);
  end;
  Put('page', IntToStr(ARequest.Page));
  Put('per_page', IntToStr(ARequest.PageSize));
  if Length(ARequest.Facets) > 0 then
  begin
    LList := '';
    for I := 0 to High(ARequest.Facets) do
    begin
      if I > 0 then
        LList := LList + ',';
      LList := LList + ARequest.Facets[I];
    end;
    Put('facet_by', LList);
    Put('max_facet_values', IntToStr(MAX_FACET_VALUES));
  end;
  if Length(ARequest.Fields) > 0 then
  begin
    LList := '';
    LHasId := False;
    for I := 0 to High(ARequest.Fields) do
    begin
      if I > 0 then
        LList := LList + ',';
      LList := LList + ARequest.Fields[I];
      if ARequest.Fields[I] = 'id' then
        LHasId := True;
    end;
    if not LHasId then
      LList := LList + ',id';
    Put('include_fields', LList);
  end;
  if Length(ARequest.Highlight) > 0 then
  begin
    LList := '';
    for I := 0 to High(ARequest.Highlight) do
    begin
      if I > 0 then
        LList := LList + ',';
      LList := LList + ARequest.Highlight[I];
    end;
    Put('highlight_fields', LList);
    Put('highlight_full_fields', LList);
    Put('highlight_start_tag', SEARCH_HIGHLIGHT_START);
    Put('highlight_end_tag', SEARCH_HIGHLIGHT_END);
    Put('enable_highlight_v1', 'false');
  end;
  // Raw: a query parameter; a JSON string goes as its text.
  for I := 0 to High(ARequest.Raw) do
  begin
    LRaw := ParseJson(ARequest.Raw[I].JsonText);
    try
      SetLength(LParams, Length(LParams) + 1);
      LParams[High(LParams)].Name := ARequest.Raw[I].Name;
      if LRaw.Kind = jkString then
        LParams[High(LParams)].Value := LRaw.AsString
      else
        LParams[High(LParams)].Value := ARequest.Raw[I].JsonText;
    finally
      LRaw.Free;
    end;
  end;

  LUrl := FPath + '/documents/search';
  for I := 0 to High(LParams) do
  begin
    if I = 0 then
      LUrl := LUrl + '?'
    else
      LUrl := LUrl + '&';
    LUrl := LUrl + Seg(LParams[I].Name) + '=' + Seg(LParams[I].Value);
  end;
  LWhat := 'GET ' + FPath + '/documents/search';
  LAnswer := FEngine.Call('GET', LUrl, '');
  LJson := ParseBody(LAnswer, LWhat);
  try
    if (SearchJsonMember(LJson, 'found') = nil) or not SearchJsonMember(LJson, 'found').TryAsInt64(LTotal) then
      raise ESearchUnavailable.CreateEngine(Format('%s %s: the answer has no "found".',
        [ENGINE_NAME, LWhat]), 0, '', '');
    LResult := TSearchResult.Create(LTotal, ARequest.Page, ARequest.PageSize, LAnswer);
    Result := LResult;
    // Typesense has no maxTotalHits: nothing past MaxHits (S17).
    LStart := Int64(ARequest.Page - 1) * ARequest.PageSize;
    LHits := SearchJsonMember(LJson, 'hits');
    if (LHits <> nil) and (LHits.Kind = jkArray) then
      for I := 0 to LHits.Count - 1 do
      begin
        if LStart + I >= LSchema.MaxHits then
          Break;
        LDoc := SearchJsonMember(LHits.Items[I], 'document');
        if LDoc = nil then
          Continue;
        LOutHit := LResult.AddHit(SearchJsonId(SearchJsonMember(LDoc, 'id')), SearchCloneJson(LDoc));
        LMarks := SearchJsonMember(LHits.Items[I], 'highlight');
        for J := 0 to High(ARequest.Highlight) do
        begin
          V := SearchJsonMember(LMarks, ARequest.Highlight[J]);
          if (V = nil) or (V.Kind <> jkObject) then
            Continue;
          if SearchJsonMember(V, 'value') <> nil then
            V := SearchJsonMember(V, 'value')
          else
            V := SearchJsonMember(V, 'snippet');
          if (V <> nil) and (V.Kind = jkString)
            and SearchHighlightFromMarked(ARequest.Highlight[J], V.AsString, LHighlight) then
            LOutHit.AddHighlight(LHighlight);
        end;
      end;
    LFacets := SearchJsonMember(LJson, 'facet_counts');
    for I := 0 to High(ARequest.Facets) do
    begin
      LOut := Default(TSearchFacet);
      LOut.Field := ARequest.Facets[I];
      if (LFacets <> nil) and (LFacets.Kind = jkArray) then
        for J := 0 to LFacets.Count - 1 do
        begin
          LFacet := LFacets.Items[J];
          if SearchJsonText(LFacet, 'field_name') <> ARequest.Facets[I] then
            Continue;
          LCounts := SearchJsonMember(LFacet, 'counts');
          if (LCounts <> nil) and (LCounts.Kind = jkArray) then
          begin
            SetLength(LOut.Values, LCounts.Count);
            for K := 0 to LCounts.Count - 1 do
            begin
              LOut.Values[K].Value := SearchJsonText(LCounts.Items[K], 'value');
              LOut.Values[K].Count := StrToIntDef(SearchJsonText(LCounts.Items[K], 'count'), 0);
            end;
          end;
          Break;
        end;
      LResult.AddFacet(LOut);
    end;
  finally
    LJson.Free;
  end;
end;

{ TTypesenseWrite }

constructor TTypesenseWrite.Create(const AFailures: TSearchFailures; AWholeBatch: Boolean);
begin
  inherited Create;
  FFailures := AFailures;
  FWholeBatch := AWholeBatch;
end;

procedure TTypesenseWrite.WaitFor(ATimeoutMs: Integer);
begin
  // Applied before the answer; refused documents are raised here, the one
  // place every adapter raises them (design, section 8).
  if Length(FFailures) > 0 then
    raise ESearchWriteFailed.CreateFailures(FFailures, FWholeBatch);
end;

function TTypesenseWrite.Pending: Boolean;
begin
  Result := False;
end;

end.
