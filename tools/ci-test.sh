#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker, on Linux FPC 3.2.2: the unit suite (core, contract suite on the
# mock, mock, both adapters on a fake transport), then the integration suite
# (the contract suite on Meilisearch v1.56.2 and on Typesense 30.2 in Docker,
# and both adapters' own tests; http and https with a private CA).
# Delphi Community Edition can't build headless, so the Delphi side is still
# validated in the IDE (see CLAUDE.md, "Tests").
#
# FPC image: built here from Debian bookworm's fpc package (3.2.2) and tagged
# pascalsearch-fpc322, unless FPC_IMAGE names an existing one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascalsearch-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'EOF' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc libssl3 && rm -rf /var/lib/apt/lists/*
EOF
fi
export FPC_IMAGE

echo "== test kit"
python tools/gen_fpc_mirror.py --check
echo "== unit suite"
sh tools/test_fpc_docker.sh
echo "== integration suite (Meilisearch, Typesense)"
sh tools/test_integration_docker.sh
