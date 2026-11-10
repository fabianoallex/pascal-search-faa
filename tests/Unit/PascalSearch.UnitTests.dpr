program PascalSearch.UnitTests;

{ DUnitX runner for the unit tests. No search engine needed: the contract
  suite runs on TMockSearchEngine (PascalSearch.ContractEnv's default).

  The sibling FPCUnit suite lives in tests/Unit/fpc, with the same coverage
  and identical test bodies: the files there are GENERATED from these by
  tools/gen_fpc_mirror.py (PascalSearch.DUnitXCompat exists for that).
  Always edit the DUnitX masters here and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalSearch.Version in '..\..\src\PascalSearch.Version.pas',
  PascalSearch.Errors in '..\..\src\PascalSearch.Errors.pas',
  PascalSearch.Values in '..\..\src\PascalSearch.Values.pas',
  PascalSearch.Schema in '..\..\src\PascalSearch.Schema.pas',
  PascalSearch.Documents in '..\..\src\PascalSearch.Documents.pas',
  PascalSearch.Filters in '..\..\src\PascalSearch.Filters.pas',
  PascalSearch.Interfaces in '..\..\src\PascalSearch.Interfaces.pas',
  PascalSearch.Query in '..\..\src\PascalSearch.Query.pas',
  PascalSearch.Mock in '..\..\src\PascalSearch.Mock.pas',
  PascalSearch.Meilisearch in '..\..\adapters\meilisearch\PascalSearch.Meilisearch.pas',
  PascalSearch.DUnitXCompat in 'PascalSearch.DUnitXCompat.pas',
  PascalSearch.ContractEnv in 'PascalSearch.ContractEnv.pas',
  PascalSearch.CoreTests in 'PascalSearch.CoreTests.pas',
  PascalSearch.ContractTests in 'PascalSearch.ContractTests.pas',
  PascalSearch.MockTests in 'PascalSearch.MockTests.pas',
  PascalSearch.MeilisearchTests in 'PascalSearch.MeilisearchTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
