unit PascalSearch.Schema;

{$I pascalsearch.inc}

{ An index's declared fields (docs/design.md, S3).

  Typesense needs a schema before the first document; Meilisearch filters,
  sorts and facets only on declared attributes, and searches every attribute
  unless told which. One declaration gives both engines, and the mock, the
  same behavior:

    Schema := TSearchSchema.New('products')
      .Text('title').Text('body')                 // searched, in this order
      .Keyword('category', [sfFilter, sfFacet])   // a string compared whole
      .Keywords('tags', [sfFilter, sfFacet])      // an array of strings
      .Num('price', [sfFilter, sfSort])           // Double
      .Int('stock', [sfFilter, sfSort])           // Int64
      .Bool('available', [sfFilter])
      .Instant('created_at', [sfFilter, sfSort])  // UTC, as Unix ms
      .Stored('image_url');                       // returned only

  Every field is optional: a document may omit it or hold null. The id is
  implicit (never declared) and filterable. A Keywords field can't be
  sorted; a Stored field takes no flags. MaxHits is the deepest hit a page
  may reach (Meilisearch's pagination.maxTotalHits, 1000 by default; a page
  beyond it raises ESearchArgumentError instead of coming back empty).

  The builder methods are named after the value kinds (Num, Int, Bool) and
  not Number/Integer/Boolean: a method called Integer would hide the type
  inside the class. }

interface

uses
  SysUtils;

type
  TSearchFieldKind = (skText, skKeyword, skKeywords, skNumber, skInteger,
    skBoolean, skInstant, skStored);

  TSearchFieldFlag = (sfFilter, sfSort, sfFacet);
  TSearchFieldFlags = set of TSearchFieldFlag;

  TSearchField = record
    Name: string;
    Kind: TSearchFieldKind;
    Flags: TSearchFieldFlags;
    /// Text: searched by the query's text.
    function IsSearchable: Boolean;
    /// Filter or Facet: both engines filter on a faceted field.
    function IsFilterable: Boolean;
    function IsSortable: Boolean;
    function IsFacet: Boolean;
  end;

  ISearchSchema = interface
    ['{4C0B2E4D-5E9A-4F43-9A3B-0C1F6D2A8B11}']
    function Name: string;
    function FieldCount: Integer;
    function Field(AIndex: Integer): TSearchField;
    function FindField(const AName: string; out AField: TSearchField): Boolean;
    function MaxHits: Integer;

    function Text(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Keyword(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Keywords(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Num(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Int(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Bool(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Instant(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Stored(const AName: string): ISearchSchema;
    /// 1 or more; the default is 1000.
    function WithMaxHits(AValue: Integer): ISearchSchema;
  end;

  TSearchSchema = class(TInterfacedObject, ISearchSchema)
  private
    FName: string;
    FFields: TArray<TSearchField>;
    FMaxHits: Integer;
    function Add(const AName: string; AKind: TSearchFieldKind; AFlags: TSearchFieldFlags): ISearchSchema;
  public
    /// Raises ESearchArgumentError for an invalid index name.
    class function New(const AIndexName: string): ISearchSchema;
    constructor Create(const AIndexName: string);
    function Name: string;
    function FieldCount: Integer;
    function Field(AIndex: Integer): TSearchField;
    function FindField(const AName: string; out AField: TSearchField): Boolean;
    function MaxHits: Integer;
    function Text(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Keyword(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Keywords(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Num(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Int(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Bool(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Instant(const AName: string; AFlags: TSearchFieldFlags = []): ISearchSchema;
    function Stored(const AName: string): ISearchSchema;
    function WithMaxHits(AValue: Integer): ISearchSchema;
  end;

const
  SEARCH_DEFAULT_MAX_HITS = 1000;

function SearchFieldKindName(AKind: TSearchFieldKind): string;

/// A copy of ASchema under the index name AName (same fields, flags and
/// MaxHits): what ReplaceIndex leaves under the target's name.
function SearchSchemaRenamed(const ASchema: ISearchSchema; const AName: string): ISearchSchema;

implementation

uses
  PascalSearch.Errors;

function SearchSchemaRenamed(const ASchema: ISearchSchema; const AName: string): ISearchSchema;
var
  LField: TSearchField;
  I: Integer;
begin
  Result := TSearchSchema.New(AName).WithMaxHits(ASchema.MaxHits);
  for I := 0 to ASchema.FieldCount - 1 do
  begin
    LField := ASchema.Field(I);
    case LField.Kind of
      skText: Result.Text(LField.Name, LField.Flags);
      skKeyword: Result.Keyword(LField.Name, LField.Flags);
      skKeywords: Result.Keywords(LField.Name, LField.Flags);
      skNumber: Result.Num(LField.Name, LField.Flags);
      skInteger: Result.Int(LField.Name, LField.Flags);
      skBoolean: Result.Bool(LField.Name, LField.Flags);
      skInstant: Result.Instant(LField.Name, LField.Flags);
    else
      Result.Stored(LField.Name);
    end;
  end;
end;

function SearchFieldKindName(AKind: TSearchFieldKind): string;
begin
  case AKind of
    skText: Result := 'text';
    skKeyword: Result := 'keyword';
    skKeywords: Result := 'keywords';
    skNumber: Result := 'number';
    skInteger: Result := 'integer';
    skBoolean: Result := 'boolean';
    skInstant: Result := 'instant';
    skStored: Result := 'stored';
  else
    Result := '?';
  end;
end;

{ TSearchField }

function TSearchField.IsSearchable: Boolean;
begin
  Result := Kind = skText;
end;

function TSearchField.IsFilterable: Boolean;
begin
  Result := (sfFilter in Flags) or (sfFacet in Flags);
end;

function TSearchField.IsSortable: Boolean;
begin
  Result := sfSort in Flags;
end;

function TSearchField.IsFacet: Boolean;
begin
  Result := sfFacet in Flags;
end;

{ TSearchSchema }

class function TSearchSchema.New(const AIndexName: string): ISearchSchema;
begin
  Result := TSearchSchema.Create(AIndexName);
end;

constructor TSearchSchema.Create(const AIndexName: string);
begin
  inherited Create;
  SearchCheckIndexName(AIndexName);
  FName := AIndexName;
  FMaxHits := SEARCH_DEFAULT_MAX_HITS;
end;

function TSearchSchema.Add(const AName: string; AKind: TSearchFieldKind;
  AFlags: TSearchFieldFlags): ISearchSchema;
var
  LField: TSearchField;
  N: Integer;
begin
  Result := Self;
  SearchCheckFieldName(AName);
  if FindField(AName, LField) then
    raise ESearchArgumentError.CreateFmt('Field "%s" is declared twice in index "%s".', [AName, FName]);
  if (AKind = skKeywords) and (sfSort in AFlags) then
    raise ESearchArgumentError.CreateFmt('Field "%s" holds an array and can''t be sorted.', [AName]);
  N := Length(FFields);
  SetLength(FFields, N + 1);
  FFields[N].Name := AName;
  FFields[N].Kind := AKind;
  FFields[N].Flags := AFlags;
end;

function TSearchSchema.Name: string;
begin
  Result := FName;
end;

function TSearchSchema.FieldCount: Integer;
begin
  Result := Length(FFields);
end;

function TSearchSchema.Field(AIndex: Integer): TSearchField;
begin
  Result := FFields[AIndex];
end;

function TSearchSchema.FindField(const AName: string; out AField: TSearchField): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if FFields[I].Name = AName then
    begin
      AField := FFields[I];
      Exit(True);
    end;
  AField := Default(TSearchField);
  Result := False;
end;

function TSearchSchema.MaxHits: Integer;
begin
  Result := FMaxHits;
end;

function TSearchSchema.Text(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skText, AFlags);
end;

function TSearchSchema.Keyword(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skKeyword, AFlags);
end;

function TSearchSchema.Keywords(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skKeywords, AFlags);
end;

function TSearchSchema.Num(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skNumber, AFlags);
end;

function TSearchSchema.Int(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skInteger, AFlags);
end;

function TSearchSchema.Bool(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skBoolean, AFlags);
end;

function TSearchSchema.Instant(const AName: string; AFlags: TSearchFieldFlags): ISearchSchema;
begin
  Result := Add(AName, skInstant, AFlags);
end;

function TSearchSchema.Stored(const AName: string): ISearchSchema;
begin
  Result := Add(AName, skStored, []);
end;

function TSearchSchema.WithMaxHits(AValue: Integer): ISearchSchema;
begin
  Result := Self;
  if AValue < 1 then
    raise ESearchArgumentError.CreateFmt('MaxHits must be 1 or more (got %d).', [AValue]);
  FMaxHits := AValue;
end;

end.
