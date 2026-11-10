#!/bin/sh
# Builds and runs the unit suite on Linux FPC 3.2.2 inside a Docker
# container, with heaptrc. Acceptance criterion: 0 errors, 0 failures,
# 0 unfreed blocks.
#
# The repository is mounted read-only and copied inside the container, so
# nothing is written to the working tree. No Lazarus needed: the FPCUnit
# runner only pulls in the LCL GUI on Windows.
#
# FPC_IMAGE: any image with FPC 3.2.2 on the PATH (default: fpc322-bookworm;
# tools/ci-test.sh builds one when it is missing).
# heaptrc on Linux only writes its summary when given a log file
# (HEAPTRC=log=...), hence the log below.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for M in pascal-common-faa/src/PascalCommon.Text.pas pascal-jsonmapper-faa/src/PascalJsonMapper.Json.pas pascal-db-faa/src/PascalDb.Outbox.pas; do
  [ -f "external/$M" ] || { echo "external/ is empty: git submodule update --init"; exit 1; }
done
python tools/gen_fpc_mirror.py --check

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u /t/external && cp -r /src/src /src/adapters /src/bridges /src/tests /t/
  cp -r /src/external/pascal-common-faa /src/external/pascal-jsonmapper-faa /src/external/pascal-db-faa /t/external/
  C=/t/external/pascal-common-faa/src
  J=/t/external/pascal-jsonmapper-faa/src
  D=/t/external/pascal-db-faa/src
  cd /t/tests/Unit/fpc
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/meilisearch -Fu/t/adapters/typesense -Fu/t/bridges/outbox -Fu$D -Fi$D -Fu$C -Fi$C -Fu$J -Fi$J -Fu/t/tests/Unit -FU/t/u -gh -gl \
    -o/t/runner PascalSearchUnitTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -B1 -A4 "Message:" /t/run.log | head -80 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
