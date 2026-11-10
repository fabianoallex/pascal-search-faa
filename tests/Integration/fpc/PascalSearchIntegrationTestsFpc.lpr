program PascalSearchIntegrationTestsFpc;

{ FPCUnit runner for the integration tests. Same coverage as the DUnitX
  suite (tests/Integration/PascalSearch.IntegrationSuite.dpr): the contract
  suite on Meilisearch plus the adapter's own tests, the fixtures generated
  from the DUnitX masters by tools/gen_fpc_mirror.py. The contract suite's
  mirror lives in tests/Unit/fpc, hence the paths below. Needs the engines
  (sh tools/engines.sh; PascalSearch.IntegrationEnv for other addresses).

  Console (text output), when called with any parameter:
    .\PascalSearchIntegrationTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalSearchIntegrationTestsFpc.exe
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
  PascalSearch.ContractEnv in '../../Unit/PascalSearch.ContractEnv.pas',
  PascalSearch.ContractTests in '../../Unit/fpc/PascalSearch.ContractTests.pas',
  PascalSearch.IntegrationEnv in '../PascalSearch.IntegrationEnv.pas',
  PascalSearch.MeilisearchIntegrationTests;

var
  ConsoleApp: TTestRunner;
begin
  // The tests' accented literals are UTF-8: a plain FPC console's code page
  // isn't, by default.
  SetMultiByteConversionCodePage(CP_UTF8);
  // The contract suite runs on Meilisearch here.
  ContractEngineFactory := MeiliContractEngine;
  ContractWait := 30000;

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
      ConsoleApp.Title := 'pascal-search-faa - integration tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
