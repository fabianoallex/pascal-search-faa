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

  0.2.0 (design, section 12): ReplaceIndex swaps a rebuilt index in; ListIds
  lists every id, past MaxHits; Highlight returns the matched words in parts
  (TSearchHighlight), never the engine's tagged text, which neither engine
  escapes; SetSynonyms replaces an index's synonym groups.

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
  /// The tags the adapters ask the engines to put around a matched word:
  /// two ASCII control characters (SOH, STX), the same on both compilers
  /// and never in a value a person typed (finding 71).
  SEARCH_HIGHLIGHT_START = #1;
  SEARCH_HIGHLIGHT_END = #2;

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
    /// Text fields whose matched words come back (ISearchHit.FindHighlight).
    Highlight: TArray<string>;
    /// The text a tmWords request sends (SearchWordsText); Text otherwise.
    function TextToSend: string;
  end;

  TSearchHighlightPart = record
    Text: string;
    /// A word (or the matched start of one) the text found.
    Matched: Boolean;
  end;

  /// A field's whole value, cut where the engine marked a match.
  TSearchHighlight = record
    Field: string;
    Parts: TArray<TSearchHighlightPart>;
    /// The value without marks.
    function Text: string;
    /// The value for a web page: & < > " ' escaped in every part, each
    /// matched part between APre and APost (written as given).
    function ToHtml(const APre: string = '<mark>'; const APost: string = '</mark>'): string;
  end;

  /// One group of SetSynonyms. Equivalent: every word finds the others.
  /// OneWay: ARoot finds the words, the words don't find ARoot. A "word" may
  /// be several ('café preto'); case and accents don't matter.
  TSearchSynonym = record
    /// '' for an equivalent group.
    Root: string;
    Words: TArray<string>;
    function IsOneWay: Boolean;
    class function Equivalent(const AWords: array of string): TSearchSynonym; static;
    class function OneWay(const ARoot: string; const AWords: array of string): TSearchSynonym; static;
  end;

  ISearchHit = interface
    ['{5B1E8C27-3F6A-4D92-8C0B-7A4E2D9F1B33}']
    function Id: string;
    /// The fields returned, id included; owned by the hit.
    function Document: TJsonValue;
    /// AField's value cut at its matches; False when the field wasn't asked
    /// (ISearchQuery.Highlight), the text was empty, or nothing in the field
    /// matched.
    function FindHighlight(const AField: string; out AHighlight: TSearchHighlight): Boolean;
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
    /// Text fields whose matched words each hit returns
    /// (ISearchHit.FindHighlight), with the field's whole value.
    function Highlight(const AFields: array of string): ISearchQuery;
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
    /// Every id of the index, or of the documents AFilter matches, past
    /// MaxHits, in no particular order. Holds one string per document.
    /// Writes during the listing may make an engine skip or repeat an id.
    function ListIds(const AFilter: ISearchFilter = nil): TArray<string>;
    /// Replaces every synonym group of the index (an empty array clears
    /// them); returns once the engine applies them to searches.
    procedure SetSynonyms(const AGroups: array of TSearchSynonym);
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
    /// ATarget serves what ASource held (documents, schema, synonyms, engine
    /// settings); the name ASource is free and what ATarget held is gone.
    /// ATarget may be missing (a rename). A missing ASource raises
    /// ESearchIndexNotFound. The step that ends a rebuild.
    procedure ReplaceIndex(const ATarget, ASource: string);
  end;

/// The text with a leading '-' of each word and every '"' removed, blanks
/// trimmed: what tmWords sends.
function SearchWordsText(const AText: string): string;

/// AMarked (a value with SEARCH_HIGHLIGHT_START/END around each match) as
/// a highlight of AField. False when nothing in it is marked.
function SearchHighlightFromMarked(const AField, AMarked: string;
  out AHighlight: TSearchHighlight): Boolean;

/// AText with & < > " ' written as HTML entities.
function SearchHtmlEscape(const AText: string): string;

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

function SearchHtmlEscape(const AText: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AText) do
    case AText[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + AText[I];
    end;
end;

function SearchHighlightFromMarked(const AField, AMarked: string;
  out AHighlight: TSearchHighlight): Boolean;
var
  LRest, LText: string;
  P: Integer;
  LMatched, LAny: Boolean;

  procedure AddPart(const APart: string; AIsMatch: Boolean);
  var
    N: Integer;
  begin
    if APart = '' then
      Exit;
    N := Length(AHighlight.Parts);
    // Two pieces of the same kind in a row (a stray marker) become one.
    if (N > 0) and (AHighlight.Parts[N - 1].Matched = AIsMatch) then
    begin
      AHighlight.Parts[N - 1].Text := AHighlight.Parts[N - 1].Text + APart;
      Exit;
    end;
    SetLength(AHighlight.Parts, N + 1);
    AHighlight.Parts[N].Text := APart;
    AHighlight.Parts[N].Matched := AIsMatch;
    if AIsMatch then
      LAny := True;
  end;

begin
  AHighlight := Default(TSearchHighlight);
  AHighlight.Field := AField;
  LAny := False;
  LMatched := False;
  LRest := AMarked;
  while LRest <> '' do
  begin
    if LMatched then
      P := Pos(SEARCH_HIGHLIGHT_END, LRest)
    else
      P := Pos(SEARCH_HIGHLIGHT_START, LRest);
    if P = 0 then
    begin
      AddPart(LRest, LMatched);
      Break;
    end;
    LText := Copy(LRest, 1, P - 1);
    AddPart(LText, LMatched);
    if LMatched then
      Delete(LRest, 1, P - 1 + Length(SEARCH_HIGHLIGHT_END))
    else
      Delete(LRest, 1, P - 1 + Length(SEARCH_HIGHLIGHT_START));
    LMatched := not LMatched;
  end;
  Result := LAny;
  if not Result then
    AHighlight.Parts := nil;
end;

{ TSearchHighlight }

function TSearchHighlight.Text: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    Result := Result + Parts[I].Text;
end;

function TSearchHighlight.ToHtml(const APre, APost: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    if Parts[I].Matched then
      Result := Result + APre + SearchHtmlEscape(Parts[I].Text) + APost
    else
      Result := Result + SearchHtmlEscape(Parts[I].Text);
end;

{ TSearchSynonym }

function TSearchSynonym.IsOneWay: Boolean;
begin
  Result := Root <> '';
end;

class function TSearchSynonym.Equivalent(const AWords: array of string): TSearchSynonym;
var
  I: Integer;
begin
  Result := Default(TSearchSynonym);
  SetLength(Result.Words, Length(AWords));
  for I := 0 to High(AWords) do
    Result.Words[I] := AWords[I];
end;

class function TSearchSynonym.OneWay(const ARoot: string; const AWords: array of string): TSearchSynonym;
begin
  Result := Equivalent(AWords);
  Result.Root := ARoot;
end;

end.
