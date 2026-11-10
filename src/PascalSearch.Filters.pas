unit PascalSearch.Filters;

{$I pascalsearch.inc}

{ Filters as a typed tree, never as text (docs/design.md, S11-S13). Each
  adapter writes its engine's syntax from the tree, quoting every value, so a
  user's value can't change the filter:

    F.All([
      F.Eq('category', 'bebida'),
      F.Between('price', 5, 8),            // inclusive
      F.Any([F.Eq('available', True), F.Gt('stock', 0)]),
      F.NoneOf('tags', ['gelada']),
      F.Ge('created_at', F.At(LSinceUtc))  // an instant: a UTC TDateTime
    ])

  F is an alias of TSearchFilters.

  What is checked here, when the filter is built (ESearchArgumentError):
  - the field name ([A-Za-z_][A-Za-z0-9_]*, or "id"): it is written unquoted;
  - Gt, Ge, Lt, Le and Between take numbers or instants only (Typesense
    compares nothing else);
  - "id" takes strings, with Eq, NotEq, AnyOf and NoneOf only;
  - AnyOf, NoneOf, All and Any need at least one item; no nil child.
  Whether the field is declared filterable, and whether the value fits its
  kind, is the engine's (and the mock's) to answer.

  On an array field, Eq and AnyOf match a document whose array holds the
  value. NotEq and NoneOf also match documents without the field (both
  engines measured). Left out on purpose, because the engines disagree or
  one lacks it: negating a group or a range, exists/null/empty tests,
  prefix and contains (S12); they go through an adapter's native access. }

interface

uses
  SysUtils,
  PascalSearch.Values;

type
  TSearchFilterOp = (fopEq, fopNotEq, fopAnyOf, fopNoneOf, fopGt, fopGe,
    fopLt, fopLe, fopBetween, fopAll, fopAny);

  ISearchFilter = interface
    ['{2D7C9B13-6A4E-4F8D-B2C1-9E5A3F7D1C44}']
    function Op: TSearchFilterOp;
    /// '' for All and Any.
    function Field: string;
    /// Eq...Le: 1; Between: 2 (low, high); AnyOf, NoneOf: 1 or more.
    function ValueCount: Integer;
    function Value(AIndex: Integer): TSearchValue;
    /// All and Any.
    function ChildCount: Integer;
    function Child(AIndex: Integer): ISearchFilter;
  end;

  TSearchFilterArray = array of ISearchFilter;

  TSearchFilters = class
  public
    /// An instant (a UTC TDateTime) as a filter value.
    class function At(AUtc: TDateTime): TSearchValue; static;

    class function Eq(const AField, AValue: string): ISearchFilter; overload; static;
    class function Eq(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function Eq(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function Eq(const AField: string; AValue: Boolean): ISearchFilter; overload; static;
    class function Eq(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;

    class function NotEq(const AField, AValue: string): ISearchFilter; overload; static;
    class function NotEq(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function NotEq(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function NotEq(const AField: string; AValue: Boolean): ISearchFilter; overload; static;
    class function NotEq(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;

    class function AnyOf(const AField: string; const AValues: array of string): ISearchFilter; overload; static;
    class function AnyOf(const AField: string; const AValues: array of Int64): ISearchFilter; overload; static;
    class function AnyOf(const AField: string; const AValues: array of TSearchValue): ISearchFilter; overload; static;
    class function NoneOf(const AField: string; const AValues: array of string): ISearchFilter; overload; static;
    class function NoneOf(const AField: string; const AValues: array of Int64): ISearchFilter; overload; static;
    class function NoneOf(const AField: string; const AValues: array of TSearchValue): ISearchFilter; overload; static;

    class function Gt(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function Gt(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function Gt(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;
    class function Ge(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function Ge(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function Ge(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;
    class function Lt(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function Lt(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function Lt(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;
    class function Le(const AField: string; AValue: Int64): ISearchFilter; overload; static;
    class function Le(const AField: string; AValue: Double): ISearchFilter; overload; static;
    class function Le(const AField: string; const AValue: TSearchValue): ISearchFilter; overload; static;

    /// Inclusive on both ends.
    class function Between(const AField: string; ALow, AHigh: Int64): ISearchFilter; overload; static;
    class function Between(const AField: string; ALow, AHigh: Double): ISearchFilter; overload; static;
    class function Between(const AField: string; const ALow, AHigh: TSearchValue): ISearchFilter; overload; static;

    /// Every child matches (and).
    class function All(const AFilters: array of ISearchFilter): ISearchFilter; static;
    /// At least one child matches (or).
    class function Any(const AFilters: array of ISearchFilter): ISearchFilter; static;
  end;

  F = TSearchFilters;

/// "eq", "not eq", "any of"... for messages.
function SearchFilterOpName(AOp: TSearchFilterOp): string;

implementation

uses
  PascalSearch.Errors;

type
  TSearchFilterNode = class(TInterfacedObject, ISearchFilter)
  private
    FOp: TSearchFilterOp;
    FField: string;
    FValues: TSearchValues;
    FChildren: TArray<ISearchFilter>;
  public
    function Op: TSearchFilterOp;
    function Field: string;
    function ValueCount: Integer;
    function Value(AIndex: Integer): TSearchValue;
    function ChildCount: Integer;
    function Child(AIndex: Integer): ISearchFilter;
  end;

function SearchFilterOpName(AOp: TSearchFilterOp): string;
begin
  case AOp of
    fopEq: Result := 'eq';
    fopNotEq: Result := 'not eq';
    fopAnyOf: Result := 'any of';
    fopNoneOf: Result := 'none of';
    fopGt: Result := 'gt';
    fopGe: Result := 'ge';
    fopLt: Result := 'lt';
    fopLe: Result := 'le';
    fopBetween: Result := 'between';
    fopAll: Result := 'all';
    fopAny: Result := 'any';
  else
    Result := '?';
  end;
end;

{ TSearchFilterNode }

function TSearchFilterNode.Op: TSearchFilterOp;
begin
  Result := FOp;
end;

function TSearchFilterNode.Field: string;
begin
  Result := FField;
end;

function TSearchFilterNode.ValueCount: Integer;
begin
  Result := Length(FValues);
end;

function TSearchFilterNode.Value(AIndex: Integer): TSearchValue;
begin
  Result := FValues[AIndex];
end;

function TSearchFilterNode.ChildCount: Integer;
begin
  Result := Length(FChildren);
end;

function TSearchFilterNode.Child(AIndex: Integer): ISearchFilter;
begin
  Result := FChildren[AIndex];
end;

{ building }

procedure CheckField(const AField: string);
begin
  if (AField <> 'id') and not SearchIsValidFieldName(AField) then
    SearchCheckFieldName(AField);   // raises with the message
end;

procedure CheckValue(AOp: TSearchFilterOp; const AField: string; const AValue: TSearchValue);
begin
  if (AOp in [fopGt, fopGe, fopLt, fopLe, fopBetween]) and not AValue.IsNumeric then
    raise ESearchArgumentError.CreateFmt('Filter "%s" on "%s": only a number or an instant ' +
      'can be compared.', [SearchFilterOpName(AOp), AField]);
  if AField = 'id' then
  begin
    if not (AOp in [fopEq, fopNotEq, fopAnyOf, fopNoneOf]) then
      raise ESearchArgumentError.CreateFmt('Filter "%s" on "id": the id takes eq, not eq, ' +
        'any of and none of only.', [SearchFilterOpName(AOp)]);
    if AValue.Kind <> svString then
      raise ESearchArgumentError.Create('A filter on "id" takes strings.');
  end;
end;

function Leaf(AOp: TSearchFilterOp; const AField: string;
  const AValues: array of TSearchValue): ISearchFilter;
var
  LNode: TSearchFilterNode;
  I: Integer;
begin
  CheckField(AField);
  if Length(AValues) = 0 then
    raise ESearchArgumentError.CreateFmt('Filter "%s" on "%s" needs at least one value.',
      [SearchFilterOpName(AOp), AField]);
  for I := 0 to High(AValues) do
    CheckValue(AOp, AField, AValues[I]);
  LNode := TSearchFilterNode.Create;
  Result := LNode;
  LNode.FOp := AOp;
  LNode.FField := AField;
  SetLength(LNode.FValues, Length(AValues));
  for I := 0 to High(AValues) do
    LNode.FValues[I] := AValues[I];
end;

function Group(AOp: TSearchFilterOp; const AFilters: array of ISearchFilter): ISearchFilter;
var
  LNode: TSearchFilterNode;
  I: Integer;
begin
  if Length(AFilters) = 0 then
    raise ESearchArgumentError.CreateFmt('Filter "%s" needs at least one filter.',
      [SearchFilterOpName(AOp)]);
  for I := 0 to High(AFilters) do
    if AFilters[I] = nil then
      raise ESearchArgumentError.CreateFmt('Filter "%s": item %d is nil.', [SearchFilterOpName(AOp), I]);
  LNode := TSearchFilterNode.Create;
  Result := LNode;
  LNode.FOp := AOp;
  SetLength(LNode.FChildren, Length(AFilters));
  for I := 0 to High(AFilters) do
    LNode.FChildren[I] := AFilters[I];
end;

function StringValues(const AValues: array of string): TSearchValues;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := TSearchValue.OfString(AValues[I]);
end;

function IntegerValues(const AValues: array of Int64): TSearchValues;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := TSearchValue.OfInteger(AValues[I]);
end;

{ TSearchFilters }

class function TSearchFilters.At(AUtc: TDateTime): TSearchValue;
begin
  Result := TSearchValue.OfInstant(AUtc);
end;

class function TSearchFilters.Eq(const AField, AValue: string): ISearchFilter;
begin
  Result := Leaf(fopEq, AField, [TSearchValue.OfString(AValue)]);
end;

class function TSearchFilters.Eq(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopEq, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.Eq(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopEq, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.Eq(const AField: string; AValue: Boolean): ISearchFilter;
begin
  Result := Leaf(fopEq, AField, [TSearchValue.OfBoolean(AValue)]);
end;

class function TSearchFilters.Eq(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopEq, AField, [AValue]);
end;

class function TSearchFilters.NotEq(const AField, AValue: string): ISearchFilter;
begin
  Result := Leaf(fopNotEq, AField, [TSearchValue.OfString(AValue)]);
end;

class function TSearchFilters.NotEq(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopNotEq, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.NotEq(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopNotEq, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.NotEq(const AField: string; AValue: Boolean): ISearchFilter;
begin
  Result := Leaf(fopNotEq, AField, [TSearchValue.OfBoolean(AValue)]);
end;

class function TSearchFilters.NotEq(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopNotEq, AField, [AValue]);
end;

class function TSearchFilters.AnyOf(const AField: string; const AValues: array of string): ISearchFilter;
begin
  Result := Leaf(fopAnyOf, AField, StringValues(AValues));
end;

class function TSearchFilters.AnyOf(const AField: string; const AValues: array of Int64): ISearchFilter;
begin
  Result := Leaf(fopAnyOf, AField, IntegerValues(AValues));
end;

class function TSearchFilters.AnyOf(const AField: string; const AValues: array of TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopAnyOf, AField, AValues);
end;

class function TSearchFilters.NoneOf(const AField: string; const AValues: array of string): ISearchFilter;
begin
  Result := Leaf(fopNoneOf, AField, StringValues(AValues));
end;

class function TSearchFilters.NoneOf(const AField: string; const AValues: array of Int64): ISearchFilter;
begin
  Result := Leaf(fopNoneOf, AField, IntegerValues(AValues));
end;

class function TSearchFilters.NoneOf(const AField: string; const AValues: array of TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopNoneOf, AField, AValues);
end;

class function TSearchFilters.Gt(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopGt, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.Gt(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopGt, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.Gt(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopGt, AField, [AValue]);
end;

class function TSearchFilters.Ge(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopGe, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.Ge(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopGe, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.Ge(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopGe, AField, [AValue]);
end;

class function TSearchFilters.Lt(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopLt, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.Lt(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopLt, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.Lt(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopLt, AField, [AValue]);
end;

class function TSearchFilters.Le(const AField: string; AValue: Int64): ISearchFilter;
begin
  Result := Leaf(fopLe, AField, [TSearchValue.OfInteger(AValue)]);
end;

class function TSearchFilters.Le(const AField: string; AValue: Double): ISearchFilter;
begin
  Result := Leaf(fopLe, AField, [TSearchValue.OfNumber(AValue)]);
end;

class function TSearchFilters.Le(const AField: string; const AValue: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopLe, AField, [AValue]);
end;

class function TSearchFilters.Between(const AField: string; ALow, AHigh: Int64): ISearchFilter;
begin
  Result := Leaf(fopBetween, AField, [TSearchValue.OfInteger(ALow), TSearchValue.OfInteger(AHigh)]);
end;

class function TSearchFilters.Between(const AField: string; ALow, AHigh: Double): ISearchFilter;
begin
  Result := Leaf(fopBetween, AField, [TSearchValue.OfNumber(ALow), TSearchValue.OfNumber(AHigh)]);
end;

class function TSearchFilters.Between(const AField: string; const ALow, AHigh: TSearchValue): ISearchFilter;
begin
  Result := Leaf(fopBetween, AField, [ALow, AHigh]);
end;

class function TSearchFilters.All(const AFilters: array of ISearchFilter): ISearchFilter;
begin
  Result := Group(fopAll, AFilters);
end;

class function TSearchFilters.Any(const AFilters: array of ISearchFilter): ISearchFilter;
begin
  Result := Group(fopAny, AFilters);
end;

end.
