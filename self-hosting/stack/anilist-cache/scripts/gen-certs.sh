#!/usr/bin/env bash
#
# Generates a private CA and a graphql.anilist.co certificate signed by it.
#
# Idempotent: existing certs are left alone unless --force is passed.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CERT_DIR=certs
HOST=graphql.anilist.co
DAYS=3650

if [[ "${1:-}" == "--force" ]]; then
  rm -f "$CERT_DIR"/*.pem "$CERT_DIR"/*.srl 2>/dev/null || true
fi

mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/server.pem" && -f "$CERT_DIR/ca.pem" ]]; then
  echo "certs already present in $CERT_DIR (use --force to regenerate)"
  openssl x509 -in "$CERT_DIR/server.pem" -noout -subject -enddate
  exit 0
fi

echo "==> private CA"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
  -keyout "$CERT_DIR/ca-key.pem" -out "$CERT_DIR/ca.pem" \
  -subj "/CN=local-anilist-cache-ca" 2>/dev/null

echo "==> server key + CSR"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$CERT_DIR/server-key.pem" -out "$CERT_DIR/server.csr" \
  -subj "/CN=$HOST" 2>/dev/null

# A modern TLS client rejects a cert whose name lives only in the subject, so
# the hostname has to appear in subjectAltName.
cat > "$CERT_DIR/server.ext" <<EOF
subjectAltName = DNS:$HOST
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
EOF

echo "==> signing"
openssl x509 -req -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -out "$CERT_DIR/server.pem" -days "$DAYS" -sha256 \
  -extfile "$CERT_DIR/server.ext" 2>/dev/null

rm -f "$CERT_DIR/server.csr" "$CERT_DIR/server.ext"
chmod 600 "$CERT_DIR"/*-key.pem

echo
openssl x509 -in "$CERT_DIR/server.pem" -noout -subject -ext subjectAltName -enddate
echo
echo "ca.pem      -> mounted into aiometadata as NODE_EXTRA_CA_CERTS"
echo "server.pem  -> presented by nginx for $HOST"
