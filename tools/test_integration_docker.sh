#!/bin/sh
# Builds and runs the integration suite on Linux FPC 3.2.2 inside Docker,
# with heaptrc, against the engines of tools/engines.sh (started here and
# removed at the end). Acceptance criterion: 0 errors, 0 failures, 0 unfreed
# blocks.
#
# The runner joins the engines' network and reaches them by name; the TLS
# tests use the private CA in .ci/it-certs. The image needs libssl3 (Debian
# 12's OpenSSL 3, loaded by pascal-common-faa without libssl-dev).
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
for M in pascal-common-faa/src/PascalCommon.Http.pas pascal-jsonmapper-faa/src/PascalJsonMapper.Json.pas; do
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
  -e SEARCH_CA_FILE=/t/.ci/it-certs/ca.pem \
  "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u /t/external /t/.ci && cp -r /src/src /src/adapters /src/tests /t/ && cp -r /src/.ci/it-certs /t/.ci/
  cp -r /src/external/pascal-common-faa /src/external/pascal-jsonmapper-faa /t/external/
  C=/t/external/pascal-common-faa/src
  J=/t/external/pascal-jsonmapper-faa/src
  cd /t/tests/Integration/fpc
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/meilisearch -Fu$C -Fi$C -Fu$J -Fi$J -Fu/t/tests/Integration -FU/t/u -gh -gl \
    -o/t/runner PascalSearchIntegrationTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -B1 -A4 "Message:" /t/run.log | head -120 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
