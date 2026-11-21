#!/usr/bin/env bash
# Exercise the release conversion with synthetic identities, never a keychain.
set -euo pipefail
umask 077
ossl=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export APPLE_DEVELOPER_ID_P12_PASSWORD='synthetic fixture only'
"$ossl" req -x509 -newkey rsa:2048 -noenc -subj /CN=Test-CA -days 1 \
  -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2>/dev/null
"$ossl" req -new -newkey rsa:2048 -noenc -subj /CN=Test-Signer \
  -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" 2>/dev/null
"$ossl" x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" \
  -set_serial 2 -days 1 -out "$tmp/leaf.crt"
for count in 1 2; do
  args=()
  if [[ $count == 2 ]]; then args=(-certfile "$tmp/ca.crt"); fi
  "$ossl" pkcs12 -export -in "$tmp/leaf.crt" -inkey "$tmp/leaf.key" \
    ${args[@]+"${args[@]}"} -passout env:APPLE_DEVELOPER_ID_P12_PASSWORD -out "$tmp/input.p12"
  bash scripts/ci/rewrap-p12.sh "$ossl" "$tmp"
  [[ ! -e "$tmp/identity.pem" ]]
  read_p12() { "$ossl" pkcs12 -legacy -in "$tmp/import.p12" -passin pass: "$@"; }
  [[ $(read_p12 -nokeys | grep -c 'BEGIN CERTIFICATE') == "$count" ]]
  cmp <(read_p12 -clcerts -nokeys | "$ossl" x509 -outform DER) <("$ossl" x509 -in "$tmp/leaf.crt" -outform DER)
  cmp <(read_p12 -nocerts -noenc | "$ossl" pkey -pubout) <("$ossl" pkey -in "$tmp/leaf.key" -pubout)
  if [[ $count == 2 ]]; then
    cmp <(read_p12 -cacerts -nokeys | "$ossl" x509 -outform DER) <("$ossl" x509 -in "$tmp/ca.crt" -outform DER)
  fi
done
