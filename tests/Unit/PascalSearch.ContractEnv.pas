unit PascalSearch.ContractEnv;

{ Which engine the contract suite (PascalSearch.ContractTests) runs on. The
  unit suite leaves the default, the mock; an integration runner sets
  ContractEngineFactory to an adapter before running, so the same test
  bodies check every engine (docs/design.md, S24).

  ContractWait is the WaitFor limit the suite passes (0: the engine's
  default). Not a test unit: the mirror generator leaves it alone, and both
  runners use this same file. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalSearch.Interfaces;

type
  TContractEngineFactory = function: ISearchEngine;

var
  ContractEngineFactory: TContractEngineFactory = nil;
  ContractWait: Integer = 0;

/// A new engine from ContractEngineFactory, or a new mock when it is nil.
function ContractEngine: ISearchEngine;

implementation

uses
  PascalSearch.Mock;

function ContractEngine: ISearchEngine;
begin
  if Assigned(ContractEngineFactory) then
    Result := ContractEngineFactory()
  else
    Result := TMockSearchEngine.New;
end;

end.
