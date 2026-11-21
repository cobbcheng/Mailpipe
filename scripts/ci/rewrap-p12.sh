#!/usr/bin/env bash
# Caller owns the private scratch directory and removes it on exit.
set +x
set -euo pipefail
umask 077
: "${import_password:?}"
ossl=$1 tmp=$2
# OpenSSL may rewind a combined PEM to find the certificates after the key.
# Keep the intermediate seekable, with its private key encrypted at rest.
pem="$tmp/identity.pem"
trap 'rm -f "$pem"' EXIT
pem_password=$("$ossl" rand -hex 32)
export pem_password
"$ossl" pkcs12 -legacy -in "$tmp/input.p12" -passin env:APPLE_DEVELOPER_ID_P12_PASSWORD \
  -aes256 -passout env:pem_password -out "$pem"
"$ossl" pkcs12 -legacy -export -macalg sha1 -in "$pem" -passin env:pem_password \
  -out "$tmp/import.p12" -passout env:import_password
