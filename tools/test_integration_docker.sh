#!/bin/sh
# Builds and runs the integration suite on Linux FPC 3.2.2 inside Docker,
# with heaptrc, against the engines of tools/engines.sh (started here and
# removed at the end): once with the contract suite on Meilisearch, once on
# Typesense. Acceptance criterion: 0 errors, 0 failures, 0 unfreed blocks,
# both times. Then sample 01-outbox on the mock and on both engines: its
# output must be samples/01-outbox/expected.txt, with 0 unfreed blocks.
#
# The runner joins the engines' network and reaches them by name; the TLS
# tests use the private CA in .ci/it-certs. The image needs libssl3 (Debian
# 12's OpenSSL 3, loaded by pascal-common-faa without libssl-dev) and, for
# the outbox bridge's tests, libsqlite3-0 (installed here when missing).
#
# FPC_IMAGE: any image with FPC 3.2.2 on the PATH (default: fpc322-bookworm;
# tools/ci-test.sh builds one when it is missing). KEEP_ENGINES=1 leaves the
# engines running.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for M in pascal-common-faa/src/PascalCommon.Http.pas pascal-jsonmapper-faa/src/PascalJsonMapper.Json.pas pascal-db-faa/src/PascalDb.Outbox.pas; do
  [ -f "external/$M" ] || { echo "external/ is missing $M: git submodule update --init"; exit 1; }
done
python tools/gen_fpc_mirror.py --check

[ "${KEEP_ENGINES:-}" = 1 ] || trap 'sh "$ROOT/tools/engines.sh" down' EXIT
sh tools/engines.sh up

MSYS_NO_PATHCONV=1 docker run --rm --network pascalsearch-it-net -v "$MOUNT:/src:ro" \
  -e SEARCH_MEILI_URL=http://meili:7700 \
  -e SEARCH_MEILI_TLS_URL=https://meili-tls:7700 \
  -e SEARCH_MEILI_TLS_WRONG_URL=https://meili-tls-other:7700 \
  -e SEARCH_MEILI_TLS_PLAIN_URL=http://meili-tls:7700 \
  -e SEARCH_TS_URL=http://typesense:8108 \
  -e SEARCH_TS_TLS_URL=https://ts-tls:8108 \
  -e SEARCH_TS_TLS_WRONG_URL=https://ts-tls-other:8108 \
  -e SEARCH_TS_TLS_PLAIN_URL=http://ts-tls:8108 \
  -e SEARCH_CA_FILE=/t/.ci/it-certs/ca.pem \
  "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u /t/external /t/.ci && cp -r /src/src /src/adapters /src/bridges /src/samples /src/tests /t/ && cp -r /src/.ci/it-certs /t/.ci/
  cp -r /src/external/pascal-common-faa /src/external/pascal-jsonmapper-faa /src/external/pascal-db-faa /t/external/
  ls /usr/lib/*/libsqlite3.so.0 >/dev/null 2>&1 \
    || { apt-get update -qq && apt-get install -y -qq --no-install-recommends libsqlite3-0 >/dev/null; }
  export SEARCH_SQLITE_CLIENT="$(ls /usr/lib/*/libsqlite3.so.0 | head -1)"
  C=/t/external/pascal-common-faa/src
  J=/t/external/pascal-jsonmapper-faa/src
  D=/t/external/pascal-db-faa
  cd /t/tests/Integration/fpc
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/meilisearch -Fu/t/adapters/typesense -Fu/t/bridges/outbox -Fu$D/src -Fi$D/src -Fu$D/adapters/sqldb -Fi$D/adapters/sqldb -Fu$C -Fi$C -Fu$J -Fi$J -Fu/t/tests/Integration -FU/t/u -gh -gl \
    -o/t/runner PascalSearchIntegrationTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  FAILED=0
  for E in meilisearch typesense; do
    echo "== contract suite on $E"
    SEARCH_CONTRACT_ENGINE=$E HEAPTRC="log=/t/heap-$E.txt" ./runner --all --format=plain > /t/run-$E.log 2>&1 || true
    grep -E "^Number of" /t/run-$E.log
    grep "unfreed" /t/heap-$E.txt
    grep -B1 -A4 "Message:" /t/run-$E.log | head -120 || true
    grep -qE "^Number of errors: +0$" /t/run-$E.log && grep -qE "^Number of failures: +0$" /t/run-$E.log \
      && grep -qE "^0 unfreed memory blocks" /t/heap-$E.txt || FAILED=1
  done
  echo "== sample 01-outbox"
  mkdir -p /t/us && cd /t/samples/01-outbox
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/meilisearch -Fu/t/adapters/typesense -Fu/t/bridges/outbox -Fu$D/src -Fi$D/src -Fu$D/adapters/sqldb -Fi$D/adapters/sqldb -Fu$C -Fi$C -Fu$J -Fi$J -FU/t/us -gh -gl \
    -o/t/sample SearchOutbox.dpr > /t/build-sample.log 2>&1 \
    || { grep -iE "error|fatal" /t/build-sample.log | head -30; exit 1; }
  cd /t
  export SEARCH_SAMPLE_SQLITE_CLIENT="$SEARCH_SQLITE_CLIENT"
  for E in mock meilisearch typesense; do
    case $E in
      meilisearch) U=http://meili:7700; K=pascal-search-it-master-key-0123 ;;
      typesense) U=http://typesense:8108; K=pascal-search-it-ts-key ;;
      *) U=; K= ;;
    esac
    SEARCH_SAMPLE_ENGINE=$E SEARCH_SAMPLE_URL=$U SEARCH_SAMPLE_KEY=$K HEAPTRC="log=/t/heap-sample-$E.txt" \
      ./sample > /t/sample-$E.log 2>&1 || true
    if sed -n "2,/^purged/p" /t/sample-$E.log | diff - /t/samples/01-outbox/expected.txt >/dev/null \
        && grep -qE "^0 unfreed memory blocks" /t/heap-sample-$E.txt; then
      echo "$E: expected output, 0 unfreed blocks"
    else
      echo "$E: FAILED"; cat /t/sample-$E.log; FAILED=1
    fi
  done
  exit $FAILED'
