unit PascalSearch.Version;

{$I pascalsearch.inc}

{ The library's version, as constants a consumer can test at compile time.

  A consumer that needs something added in a given version states it, so an
  older copy of pascal-search-faa fails the build with a clear message
  instead of a missing identifier somewhere inside the consumer:

    (*$IF PASCALSEARCH_VERSION < 200*)
      (*$MESSAGE FATAL 'my-app needs pascal-search-faa 0.2.0 or later'*)
    (*$IFEND*)

  (braces instead of the parenthesized form in real code), with
  PascalSearch.Version in that unit's uses: a constant is only seen by the
  units that use the unit declaring it. Same format as PASCALCOMMON_VERSION
  (pascal-common-faa).

  Bump every constant here with each release, together with the version in
  the packages/*.lpk files, README.md and CHANGELOG.md. }

interface

const
  PASCALSEARCH_VERSION_MAJOR = 0;
  PASCALSEARCH_VERSION_MINOR = 1;
  PASCALSEARCH_VERSION_PATCH = 0;

  /// major * 10000 + minor * 100 + patch: 0.2.0 is 200, 1.2.3 is 10203.
  PASCALSEARCH_VERSION = 100;

  PASCALSEARCH_VERSION_STRING = '0.1.0';

implementation

end.
