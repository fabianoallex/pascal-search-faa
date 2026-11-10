unit PascalSearch.Query;

{$I pascalsearch.inc}

{ The pieces every adapter and the mock share: the query builder, which
  checks what can be checked without the engine and hands a TSearchRequest
  to the index's ISearchExecutor, and the result classes, which own their
  JSON documents and keep facet values in the contract's order (count
  descending, then value).

  Checked by the builder (ESearchArgumentError): field names in OrderBy,
  Facets and Fields; page from 1 and page size 0-250; a Raw parameter's name
  and JSON. Checked by the index when it runs the query: the page against
  the schema's MaxHits, and (by the engine) whether fields are declared. }

interface

uses
  SysUtils,
  PascalJsonMapper.Json,
  PascalSearch.Filters,
  PascalSearch.Interfaces;

type
  TSearchQuery = class(TInterfacedObject, ISearchQuery)
  private
    FExecutor: ISearchExecutor;
    FRequest: TSearchRequest;
    procedure AddSort(const AField: string; AOrder: TSearchSortOrder);
  public
    constructor Create(const AExecutor: ISearchExecutor; const AText: string);
    function Where(const AFilter: ISearchFilter): ISearchQuery;
    function OrderBy(const AField: string; AOrder: TSearchSortOrder = soAsc): ISearchQuery;
    function ThenBy(const AField: string; AOrder: TSearchSortOrder = soAsc): ISearchQuery;
    function Page(APage, APageSize: Integer): ISearchQuery;
    function Facets(const AFields: array of string): ISearchQuery;
    function Fields(const AFields: array of string): ISearchQuery;
    function Words(AWords: TSearchWords): ISearchQuery;
    function TextMode(AMode: TSearchTextMode): ISearchQuery;
    function Raw(const AName, AJsonText: string): ISearchQuery;
    function Request: TSearchRequest;
    function Execute: ISearchResult;
  end;

  TSearchHit = class(TInterfacedObject, ISearchHit)
  private
    FId: string;
    FDocument: TJsonValue;
  public
    /// Takes ownership of ADocument.
    constructor Create(const AId: string; ADocument: TJsonValue);
    destructor Destroy; override;
    function Id: string;
    function Document: TJsonValue;
  end;

  TSearchHitList = class(TInterfacedObject, ISearchHits)
  private
    FHits: TArray<ISearchHit>;
  public
    /// Takes ownership of ADocument.
    procedure AddHit(const AId: string; ADocument: TJsonValue);
    function Count: Integer;
    function Hit(AIndex: Integer): ISearchHit;
  end;

  TSearchResult = class(TSearchHitList, ISearchResult)
  private
    FTotal: Int64;
    FPage: Integer;
    FPageSize: Integer;
    FFacets: TArray<TSearchFacet>;
    FRawJson: string;
  public
    constructor Create(ATotal: Int64; APage, APageSize: Integer; const ARawJson: string = '');
    /// Sorts AFacet's values into the contract's order.
    procedure AddFacet(const AFacet: TSearchFacet);
    function Total: Int64;
    function Page: Integer;
    function PageSize: Integer;
    function FacetCount: Integer;
    function Facet(AIndex: Integer): TSearchFacet;
    function FindFacet(const AField: string; out AFacet: TSearchFacet): Boolean;
    function RawJson: string;
  end;

/// Count descending, then value by ordinal: the contract's facet order.
procedure SearchSortFacetValues(var AValues: TArray<TSearchFacetValue>);

implementation

uses
  PascalSearch.Errors;

procedure SearchSortFacetValues(var AValues: TArray<TSearchFacetValue>);
var
  I, J: Integer;
  LItem: TSearchFacetValue;

  function Before(const A, B: TSearchFacetValue): Boolean;
  begin
    if A.Count <> B.Count then
      Result := A.Count > B.Count
    else
      Result := CompareStr(A.Value, B.Value) < 0;
  end;

begin
  // Insertion sort: facets have few values, and it is stable.
  for I := 1 to High(AValues) do
  begin
    LItem := AValues[I];
    J := I - 1;
    while (J >= 0) and Before(LItem, AValues[J]) do
    begin
      AValues[J + 1] := AValues[J];
      Dec(J);
    end;
    AValues[J + 1] := LItem;
  end;
end;

procedure CheckFieldOrId(const AName: string);
begin
  if AName <> 'id' then
    SearchCheckFieldName(AName);
end;

{ TSearchQuery }

constructor TSearchQuery.Create(const AExecutor: ISearchExecutor; const AText: string);
begin
  inherited Create;
  FExecutor := AExecutor;
  FRequest := Default(TSearchRequest);
  FRequest.Text := AText;
  FRequest.TextMode := tmWords;
  FRequest.Words := swAll;
  FRequest.Page := 1;
  FRequest.PageSize := SEARCH_DEFAULT_PAGE_SIZE;
end;

function TSearchQuery.Where(const AFilter: ISearchFilter): ISearchQuery;
begin
  Result := Self;
  FRequest.Filter := AFilter;
end;

procedure TSearchQuery.AddSort(const AField: string; AOrder: TSearchSortOrder);
var
  N: Integer;
begin
  SearchCheckFieldName(AField);
  N := Length(FRequest.Sorts);
  SetLength(FRequest.Sorts, N + 1);
  FRequest.Sorts[N].Field := AField;
  FRequest.Sorts[N].Order := AOrder;
end;

function TSearchQuery.OrderBy(const AField: string; AOrder: TSearchSortOrder): ISearchQuery;
begin
  Result := Self;
  SetLength(FRequest.Sorts, 0);
  AddSort(AField, AOrder);
end;

function TSearchQuery.ThenBy(const AField: string; AOrder: TSearchSortOrder): ISearchQuery;
begin
  Result := Self;
  AddSort(AField, AOrder);
end;

function TSearchQuery.Page(APage, APageSize: Integer): ISearchQuery;
begin
  Result := Self;
  if APage < 1 then
    raise ESearchArgumentError.CreateFmt('The page starts at 1 (got %d).', [APage]);
  if (APageSize < 0) or (APageSize > SEARCH_MAX_PAGE_SIZE) then
    raise ESearchArgumentError.CreateFmt('The page size goes from 0 to %d (got %d).',
      [SEARCH_MAX_PAGE_SIZE, APageSize]);
  FRequest.Page := APage;
  FRequest.PageSize := APageSize;
end;

function TSearchQuery.Facets(const AFields: array of string): ISearchQuery;
var
  I: Integer;
begin
  Result := Self;
  for I := 0 to High(AFields) do
    SearchCheckFieldName(AFields[I]);
  SetLength(FRequest.Facets, Length(AFields));
  for I := 0 to High(AFields) do
    FRequest.Facets[I] := AFields[I];
end;

function TSearchQuery.Fields(const AFields: array of string): ISearchQuery;
var
  I: Integer;
begin
  Result := Self;
  for I := 0 to High(AFields) do
    CheckFieldOrId(AFields[I]);
  SetLength(FRequest.Fields, Length(AFields));
  for I := 0 to High(AFields) do
    FRequest.Fields[I] := AFields[I];
end;

function TSearchQuery.Words(AWords: TSearchWords): ISearchQuery;
begin
  Result := Self;
  FRequest.Words := AWords;
end;

function TSearchQuery.TextMode(AMode: TSearchTextMode): ISearchQuery;
begin
  Result := Self;
  FRequest.TextMode := AMode;
end;

function TSearchQuery.Raw(const AName, AJsonText: string): ISearchQuery;
var
  LValue: TJsonValue;
  N: Integer;
begin
  Result := Self;
  if not SearchIsValidFieldName(AName) then
    raise ESearchArgumentError.CreateFmt('Invalid engine parameter name "%s".', [AName]);
  try
    LValue := ParseJson(AJsonText);
    LValue.Free;
  except
    on E: EJsonError do
      raise ESearchArgumentError.CreateFmt('Engine parameter "%s": %s', [AName, E.Message]);
  end;
  N := Length(FRequest.Raw);
  SetLength(FRequest.Raw, N + 1);
  FRequest.Raw[N].Name := AName;
  FRequest.Raw[N].JsonText := AJsonText;
end;

function TSearchQuery.Request: TSearchRequest;
begin
  Result := FRequest;
end;

function TSearchQuery.Execute: ISearchResult;
begin
  Result := FExecutor.ExecuteSearch(FRequest);
end;

{ TSearchHit }

constructor TSearchHit.Create(const AId: string; ADocument: TJsonValue);
begin
  inherited Create;
  FId := AId;
  FDocument := ADocument;
end;

destructor TSearchHit.Destroy;
begin
  FDocument.Free;
  inherited Destroy;
end;

function TSearchHit.Id: string;
begin
  Result := FId;
end;

function TSearchHit.Document: TJsonValue;
begin
  Result := FDocument;
end;

{ TSearchHitList }

procedure TSearchHitList.AddHit(const AId: string; ADocument: TJsonValue);
var
  N: Integer;
begin
  N := Length(FHits);
  SetLength(FHits, N + 1);
  FHits[N] := TSearchHit.Create(AId, ADocument);
end;

function TSearchHitList.Count: Integer;
begin
  Result := Length(FHits);
end;

function TSearchHitList.Hit(AIndex: Integer): ISearchHit;
begin
  Result := FHits[AIndex];
end;

{ TSearchResult }

constructor TSearchResult.Create(ATotal: Int64; APage, APageSize: Integer; const ARawJson: string);
begin
  inherited Create;
  FTotal := ATotal;
  FPage := APage;
  FPageSize := APageSize;
  FRawJson := ARawJson;
end;

procedure TSearchResult.AddFacet(const AFacet: TSearchFacet);
var
  N: Integer;
begin
  N := Length(FFacets);
  SetLength(FFacets, N + 1);
  FFacets[N].Field := AFacet.Field;
  FFacets[N].Values := Copy(AFacet.Values, 0, Length(AFacet.Values));
  SearchSortFacetValues(FFacets[N].Values);
end;

function TSearchResult.Total: Int64;
begin
  Result := FTotal;
end;

function TSearchResult.Page: Integer;
begin
  Result := FPage;
end;

function TSearchResult.PageSize: Integer;
begin
  Result := FPageSize;
end;

function TSearchResult.FacetCount: Integer;
begin
  Result := Length(FFacets);
end;

function TSearchResult.Facet(AIndex: Integer): TSearchFacet;
begin
  Result := FFacets[AIndex];
end;

function TSearchResult.FindFacet(const AField: string; out AFacet: TSearchFacet): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FFacets) do
    if FFacets[I].Field = AField then
    begin
      AFacet := FFacets[I];
      Exit(True);
    end;
  AFacet := Default(TSearchFacet);
  Result := False;
end;

function TSearchResult.RawJson: string;
begin
  Result := FRawJson;
end;

end.
