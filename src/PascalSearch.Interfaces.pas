unit PascalSearch.Interfaces;

{$I pascalsearch.inc}

{ The contract every engine adapter and the mock implement
  (docs/design.md, section 3).

  ISearchEngine is one server; ISearchIndex one index on it. Writes return an
  ISearchWrite: Meilisearch applies them later and reports a refused document
  only in its task, so a caller that needs the result waits (WaitFor), and
  WaitFor is where every adapter raises ESearchWriteFailed. Typesense applies
  a write before answering, so its WaitFor returns at once.

  A search is built on ISearchQuery and run by Execute; the query's data is a
  TSearchRequest, which is what an adapter reads (through ISearchExecutor).
  Results own the JSON documents they hold: keep the result (or the hit)
  while using one.

  Engines and indexes may be shared between threads; queries, documents and
  results belong to the thread that built them. }

interface

uses
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Schema,
  PascalSearch.Documents,
  PascalSearch.Filters;

const
  SEARCH_DEFAULT_PAGE_SIZE = 20;
  /// Typesense's limit (422 above it), the common ground.
  SEARCH_MAX_PAGE_SIZE = 250;

type
  TSearchSortOrder = (soAsc, soDesc);

  /// swAll: every word must match (the default). swRelaxed: the engine drops
  /// words from the end when nothing matches them all (the engines' own
  /// default; Meilisearch "last", Typesense drop_tokens_threshold 1).
  TSearchWords = (swAll, swRelaxed);

  /// tmWords: the text is words; a leading '-' and every '"' are removed
  /// before sending (both engines read them as "without" and "phrase").
  /// tmEngine: the text goes as typed, with the engine's syntax.
  TSearchTextMode = (tmWords, tmEngine);

  TSearchSort = record
    Field: string;
    Order: TSearchSortOrder;
  end;

  /// An engine parameter added as is (ISearchQuery.Raw).
  TSearchRawParam = record
    Name: string;
    JsonText: string;
  end;

  TSearchRequest = record
    Text: string;
    TextMode: TSearchTextMode;
    Words: TSearchWords;
    /// nil: no filter.
    Filter: ISearchFilter;
    Sorts: TArray<TSearchSort>;
    /// 1-based.
    Page: Integer;
    /// 0: the total and the facets only.
    PageSize: Integer;
    Facets: TArray<string>;
    /// Empty: every stored field. The id always comes back.
    Fields: TArray<string>;
    Raw: TArray<TSearchRawParam>;
    /// The text a tmWords request sends (SearchWordsText); Text otherwise.
    function TextToSend: string;
  end;

  ISearchHit = interface
    ['{5B1E8C27-3F6A-4D92-8C0B-7A4E2D9F1B33}']
    function Id: string;
    /// The fields returned, id included; owned by the hit.
    function Document: TJsonValue;
  end;

  ISearchHits = interface
    ['{9C3D1A45-7E2B-4F06-A8D1-3B6F5C2E4A55}']
    function Count: Integer;
    function Hit(AIndex: Integer): ISearchHit;
  end;

  TSearchFacetValue = record
    Value: string;
    Count: Integer;
  end;

  /// Values by count, highest first; equal counts by value (ordinal).
  TSearchFacet = record
    Field: string;
    Values: TArray<TSearchFacetValue>;
  end;

  ISearchResult = interface(ISearchHits)
    ['{1F4B7D29-8A3C-4E51-9D6E-2C7A5B3F8D66}']
    /// Every match, exact; the hits are one page of it.
    function Total: Int64;
    function Page: Integer;
    function PageSize: Integer;
    function FacetCount: Integer;
    function Facet(AIndex: Integer): TSearchFacet;
    function FindFacet(const AField: string; out AFacet: TSearchFacet): Boolean;
    /// The engine's answer as received ('' on the mock).
    function RawJson: string;
  end;

  ISearchQuery = interface
    ['{6E2A9F31-4C7B-4D18-B5E3-8F1D6A2C9E77}']
    function Where(const AFilter: ISearchFilter): ISearchQuery;
    /// Replaces the sort with this field.
    function OrderBy(const AField: string; AOrder: TSearchSortOrder = soAsc): ISearchQuery;
    /// Adds a field to the sort.
    function ThenBy(const AField: string; AOrder: TSearchSortOrder = soAsc): ISearchQuery;
    /// APage from 1; APageSize 0-250 (0: total and facets only).
    function Page(APage, APageSize: Integer): ISearchQuery;
    function Facets(const AFields: array of string): ISearchQuery;
    function Fields(const AFields: array of string): ISearchQuery;
    function Words(AWords: TSearchWords): ISearchQuery;
    function TextMode(AMode: TSearchTextMode): ISearchQuery;
    /// An engine parameter, AJsonText being its JSON value: a member of
    /// Meilisearch's body, a query parameter on Typesense. The mock refuses
    /// it (ESearchNotSupported).
    function Raw(const AName, AJsonText: string): ISearchQuery;
    function Request: TSearchRequest;
    function Execute: ISearchResult;
  end;

  /// What runs a query: the index that made it.
  ISearchExecutor = interface
    ['{3A8E5C17-2D9F-4B64-A1C7-6E4B8D2F5A88}']
    function ExecuteSearch(const ARequest: TSearchRequest): ISearchResult;
  end;

  ISearchWrite = interface
    ['{7D5F2B39-1E8A-4C73-B6D2-9A3C7E1F4B99}']
    /// Returns once the write is searchable. Raises ESearchWriteFailed when
    /// the engine refused documents, ESearchTimeout when the write is still
    /// pending after ATimeoutMs (0: the engine's configured default).
    procedure WaitFor(ATimeoutMs: Integer = 0);
    /// True while the engine hasn't applied the write.
    function Pending: Boolean;
  end;

  ISearchIndex = interface
    ['{4E9A3C51-6B2D-4F87-8E1A-5D7C3B9F2EAA}']
    function Name: string;
    /// Adds or replaces whole documents.
    function Upsert(const ADocs: array of ISearchDocument): ISearchWrite;
    /// A missing id is not an error.
    function Delete(const AIds: array of string): ISearchWrite;
    function DeleteWhere(const AFilter: ISearchFilter): ISearchWrite;
    /// nil when there is no such document.
    function Get(const AId: string): ISearchHit;
    /// The documents found, in the order asked; missing ids left out.
    function GetMany(const AIds: array of string): ISearchHits;
    /// '' (or blanks) matches every document.
    function Search(const AText: string): ISearchQuery;
  end;

  ISearchEngine = interface
    ['{8B6C4E21-9D3A-4E15-A7F2-1C8E5B3D7ABB}']
    /// Creates the index, or brings an existing one up to ASchema. A change
    /// the engine can't make in place (a field's kind) raises
    /// ESearchSchemaError: drop and rebuild the index.
    function EnsureIndex(const ASchema: ISearchSchema): ISearchIndex;
    /// No request: an index never ensured raises ESearchIndexNotFound on
    /// use (the mock and Typesense; Meilisearch would create it without a
    /// schema on the first write, so don't rely on that).
    function Index(const AName: string): ISearchIndex;
    function IndexExists(const AName: string): Boolean;
    /// A missing index is not an error.
    procedure DropIndex(const AName: string);
  end;

/// The text with a leading '-' of each word and every '"' removed, blanks
/// trimmed: what tmWords sends.
function SearchWordsText(const AText: string): string;

implementation

function IsBlank(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

function SearchWordsText(const AText: string): string;
var
  I: Integer;
  LAtWordStart: Boolean;
  C: Char;
begin
  Result := '';
  LAtWordStart := True;
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if C = '"' then
      Continue;
    if IsBlank(C) then
    begin
      LAtWordStart := True;
      Result := Result + ' ';
      Continue;
    end;
    if (C = '-') and LAtWordStart then
      Continue;
    LAtWordStart := False;
    Result := Result + C;
  end;
  Result := Trim(Result);
end;

{ TSearchRequest }

function TSearchRequest.TextToSend: string;
begin
  if TextMode = tmWords then
    Result := SearchWordsText(Text)
  else
    Result := Text;
end;

end.
