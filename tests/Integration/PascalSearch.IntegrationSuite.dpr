program PascalSearch.IntegrationSuite;

{ DUnitX runner for the integration tests: the contract suite
  (tests/Unit/PascalSearch.ContractTests.pas) pointed at Meilisearch or Typesense
  (SEARCH_CONTRACT_ENGINE) through PascalSearch.ContractEnv, plus both
  adapters' own tests, and the outbox bridge end to end on a SQLite
  database (FireDAC; pascal-db-faa's units come from external/pascal-db-faa,
  on the search path). Needs the engines:
  "sh tools/engines.sh" starts them in Docker on this machine (host ports
  17700 and 17701); PascalSearch.IntegrationEnv says how to point elsewhere.

  The sibling FPCUnit runner is tests/Integration/fpc; its fixtures are
  generated from these masters by tools/gen_fpc_mirror.py. }

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
  PascalSearch.EngineJson in '..\..\src\PascalSearch.EngineJson.pas',
  PascalSearch.Meilisearch in '..\..\adapters\meilisearch\PascalSearch.Meilisearch.pas',
  PascalSearch.Typesense in '..\..\adapters\typesense\PascalSearch.Typesense.pas',
  PascalSearch.Outbox in '..\..\bridges\outbox\PascalSearch.Outbox.pas',
  PascalSearch.DUnitXCompat in '..\Unit\PascalSearch.DUnitXCompat.pas',
  PascalSearch.ContractEnv in '..\Unit\PascalSearch.ContractEnv.pas',
  PascalSearch.ContractTests in '..\Unit\PascalSearch.ContractTests.pas',
  PascalSearch.IntegrationEnv in 'PascalSearch.IntegrationEnv.pas',
  PascalSearch.MeilisearchIntegrationTests in 'PascalSearch.MeilisearchIntegrationTests.pas',
  PascalSearch.TypesenseIntegrationTests in 'PascalSearch.TypesenseIntegrationTests.pas',
  PascalSearch.OutboxIntegrationTests in 'PascalSearch.OutboxIntegrationTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  // The contract suite runs on the engine SEARCH_CONTRACT_ENGINE names
  // (meilisearch by default); the scripts run this program once per engine.
  ContractEngineFactory := IntegrationContractEngine;
  ContractWait := 30000;
  System.Writeln('Contract suite on: ', ContractEngineName);
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
