#!/bin/sh
# Starts (up, the default) or removes (down) the search engines the
# integration suite runs against, in Docker, versions pinned:
#   pascalsearch-it-meili      Meilisearch over http,  host port 17700
#   pascalsearch-it-meili-tls  Meilisearch over https, host port 17701, with a
#                              certificate from a private CA made here
# Both on the network pascalsearch-it-net (aliases meili, meili-tls and
# meili-tls-other, a name the certificate doesn't hold).
#
# The CA and the server certificate go to .ci/it-certs (git-ignored) and are
# made once, with openssl in a debian:bookworm container. The certificate
# names localhost and meili-tls; 127.0.0.1 and meili-tls-other are left out on
# purpose, to test a wrong host name.
#
# The runners' defaults point at the host ports (tests/Integration,
# PascalSearch.IntegrationEnv), so after "sh tools/engines.sh" the Delphi and
# the FPC Windows runners work as they are. tools/test_integration_docker.sh
# runs the Linux one inside the network. Only these containers are touched.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-up}"
NET=pascalsearch-it-net
MEILI_IMG=getmeili/meilisearch:v1.56.2
KEY=pascal-search-it-master-key-0123
NAMES="pascalsearch-it-meili pascalsearch-it-meili-tls"
CERTS="$ROOT/.ci/it-certs"
MOUNT="$CERTS"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$CERTS")"

down() {
  docker rm -f $NAMES >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}

if [ "$CMD" = down ]; then
  down
  exit 0
fi
[ "$CMD" = up ] || { echo "usage: sh tools/engines.sh [up|down]"; exit 2; }
down

mkdir -p "$CERTS"
if [ ! -f "$CERTS/server.pem" ]; then
  echo "== certificates (.ci/it-certs)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/c" debian:bookworm sh -c '
    set -e
    apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null
    cd /c
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=pascal-search-it CA" \
      -keyout ca.key -out ca.pem 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=meili-tls" -keyout server.key -out server.csr 2>/dev/null
    printf "subjectAltName=DNS:meili-tls,DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" > ext.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext.cnf -out server.pem 2>/dev/null
    rm -f server.csr ext.cnf ca.srl
    chmod 644 /c/*'
fi

echo "== engines"
docker network create $NET >/dev/null
MSYS_NO_PATHCONV=1 docker run -d --name pascalsearch-it-meili --network $NET --network-alias meili \
  -p 17700:7700 -e MEILI_MASTER_KEY=$KEY -e MEILI_NO_ANALYTICS=true $MEILI_IMG >/dev/null
MSYS_NO_PATHCONV=1 docker run -d --name pascalsearch-it-meili-tls --network $NET \
  --network-alias meili-tls --network-alias meili-tls-other -p 17701:7700 -v "$MOUNT:/certs:ro" \
  -e MEILI_MASTER_KEY=$KEY -e MEILI_NO_ANALYTICS=true $MEILI_IMG \
  meilisearch --ssl-cert-path /certs/server.pem --ssl-key-path /certs/server.key >/dev/null

# Ready when both answer /health (no key needed, finding 38).
for i in $(seq 1 60); do
  if docker exec pascalsearch-it-meili curl -sf http://localhost:7700/health >/dev/null 2>&1 \
    && docker exec pascalsearch-it-meili-tls curl -sfk https://localhost:7700/health >/dev/null 2>&1; then
    echo "ready: http://localhost:17700, https://localhost:17701 (CA: .ci/it-certs/ca.pem)"
    exit 0
  fi
  sleep 1
done
echo "the engines didn't answer in 60 s"
docker logs pascalsearch-it-meili-tls 2>&1 | tail -20
exit 1
