program PascalSearchUnitTestsFpc;

{ FPCUnit runner for the unit tests. Same coverage as the DUnitX suite
  (tests/Unit/PascalSearch.UnitTests.dpr): the fixtures in tests/Unit/fpc are
  generated from the DUnitX masters by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\PascalSearchUnitTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalSearchUnitTestsFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalSearch.CoreTests,
  PascalSearch.ContractTests,
  PascalSearch.MockTests,
  PascalSearch.MeilisearchTests,
  PascalSearch.TypesenseTests,
  PascalSearch.OutboxTests;

var
  ConsoleApp: TTestRunner;
begin
  // The tests' accented literals are UTF-8: a plain FPC console's code page
  // isn't, by default.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-search-faa - unit tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
