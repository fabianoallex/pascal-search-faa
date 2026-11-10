unit PascalSearch.Values;

{$I pascalsearch.inc}

{ A field value as the filters and the mock see it, and the two conversions
  every adapter needs to write values the same way:

  - an instant is a TDateTime in UTC, stored and compared as Unix
    milliseconds (Int64): neither engine compares date text, and Meilisearch
    answers 0 hits silently to one (docs/design.md, S9);
  - a number goes into a filter in plain decimal with '.', never with an
    exponent: Meilisearch answers 0 hits to "1e1" and Typesense matches
    nothing (S10). NaN and infinity are refused (ESearchArgumentError). }

interface

uses
  SysUtils;

type
  TSearchValueKind = (svString, svInteger, svNumber, svBoolean, svInstant);

  TSearchValue = record
  private
    FKind: TSearchValueKind;
    FText: string;
    FInteger: Int64;
    FNumber: Double;
    FBoolean: Boolean;
  public
    class function OfString(const AValue: string): TSearchValue; static;
    class function OfInteger(AValue: Int64): TSearchValue; static;
    /// Raises ESearchArgumentError for NaN or infinity.
    class function OfNumber(AValue: Double): TSearchValue; static;
    class function OfBoolean(AValue: Boolean): TSearchValue; static;
    /// AUtc as Unix milliseconds (AsInteger).
    class function OfInstant(AUtc: TDateTime): TSearchValue; static;
    property Kind: TSearchValueKind read FKind;
    function AsString: string;
    /// svInteger, svInstant (milliseconds).
    function AsInteger: Int64;
    /// svInteger, svNumber, svInstant.
    function AsNumber: Double;
    function AsBoolean: Boolean;
    function IsNumeric: Boolean;
    /// The value as a filter writes it, without quoting: the text as is, a
    /// number in plain decimal, true/false, an instant's milliseconds.
    function ToFilterText: string;
  end;

  TSearchValues = TArray<TSearchValue>;

/// AUtc (a UTC TDateTime) as Unix milliseconds, rounded to the nearest one.
function SearchInstantToMs(AUtc: TDateTime): Int64;
/// Back to a UTC TDateTime.
function SearchMsToInstant(AMs: Int64): TDateTime;

/// AValue in plain decimal: '.' as separator, no exponent, the shortest text
/// that reads back as the same Double. Raises ESearchArgumentError for NaN
/// or infinity.
function SearchNumberText(AValue: Double): string;

implementation

uses
  Math,
  PascalJsonMapper.Json,
  PascalSearch.Errors;

const
  UNIX_EPOCH = 25569.0;   // 1970-01-01 as a TDateTime

function SearchInstantToMs(AUtc: TDateTime): Int64;
begin
  Result := Round((AUtc - UNIX_EPOCH) * MSecsPerDay);
end;

function SearchMsToInstant(AMs: Int64): TDateTime;
begin
  Result := UNIX_EPOCH + AMs / MSecsPerDay;
end;

// "1.5E21" or "1E-7" (JsonFloatToStr's form beyond its plain range) to
// plain decimal.
function ExpandExponent(const AText: string): string;
var
  P, LExp, LDot: Integer;
  LNegative: Boolean;
  LDigits, LMantissa: string;
begin
  P := Pos('E', AText);
  if P = 0 then
    Exit(AText);
  LMantissa := Copy(AText, 1, P - 1);
  LExp := StrToInt(Copy(AText, P + 1, MaxInt));
  LNegative := (LMantissa <> '') and (LMantissa[1] = '-');
  if LNegative then
    Delete(LMantissa, 1, 1);
  LDot := Pos('.', LMantissa);
  if LDot > 0 then
  begin
    LDigits := Copy(LMantissa, 1, LDot - 1) + Copy(LMantissa, LDot + 1, MaxInt);
    LExp := LExp - (Length(LMantissa) - LDot);
  end
  else
    LDigits := LMantissa;
  // Now the value is LDigits * 10^LExp, LDigits an integer without sign.
  if LExp >= 0 then
    Result := LDigits + StringOfChar('0', LExp)
  else if -LExp < Length(LDigits) then
    Result := Copy(LDigits, 1, Length(LDigits) + LExp) + '.' +
      Copy(LDigits, Length(LDigits) + LExp + 1, MaxInt)
  else
    Result := '0.' + StringOfChar('0', -LExp - Length(LDigits)) + LDigits;
  if LNegative then
    Result := '-' + Result;
end;

function SearchNumberText(AValue: Double): string;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    raise ESearchArgumentError.Create('A search value can''t be NaN or infinity.');
  Result := ExpandExponent(JsonFloatToStr(AValue));
end;

{ TSearchValue }

class function TSearchValue.OfString(const AValue: string): TSearchValue;
begin
  Result := Default(TSearchValue);
  Result.FKind := svString;
  Result.FText := AValue;
end;

class function TSearchValue.OfInteger(AValue: Int64): TSearchValue;
begin
  Result := Default(TSearchValue);
  Result.FKind := svInteger;
  Result.FInteger := AValue;
  Result.FNumber := AValue;
end;

class function TSearchValue.OfNumber(AValue: Double): TSearchValue;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    raise ESearchArgumentError.Create('A search value can''t be NaN or infinity.');
  Result := Default(TSearchValue);
  Result.FKind := svNumber;
  Result.FNumber := AValue;
end;

class function TSearchValue.OfBoolean(AValue: Boolean): TSearchValue;
begin
  Result := Default(TSearchValue);
  Result.FKind := svBoolean;
  Result.FBoolean := AValue;
end;

class function TSearchValue.OfInstant(AUtc: TDateTime): TSearchValue;
begin
  Result := Default(TSearchValue);
  Result.FKind := svInstant;
  Result.FInteger := SearchInstantToMs(AUtc);
  Result.FNumber := Result.FInteger;
end;

function TSearchValue.AsString: string;
begin
  Result := FText;
end;

function TSearchValue.AsInteger: Int64;
begin
  Result := FInteger;
end;

function TSearchValue.AsNumber: Double;
begin
  Result := FNumber;
end;

function TSearchValue.AsBoolean: Boolean;
begin
  Result := FBoolean;
end;

function TSearchValue.IsNumeric: Boolean;
begin
  Result := FKind in [svInteger, svNumber, svInstant];
end;

function TSearchValue.ToFilterText: string;
begin
  case FKind of
    svString: Result := FText;
    svInteger, svInstant: Result := IntToStr(FInteger);
    svNumber: Result := SearchNumberText(FNumber);
    svBoolean:
      if FBoolean then Result := 'true' else Result := 'false';
  else
    Result := '';
  end;
end;

end.
