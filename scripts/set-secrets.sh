#!/usr/bin/env bash
# Uploads the test keys from _testkeys/ as repository / environment secrets.
# Run from the repo root in Git Bash. Prints sizes only, never values.
# Values go to gh through stdin redirection from a file, so the bytes are not re-encoded.
set -euo pipefail

gh=${GH:-gh}
repo=${REPO:?set REPO=owner/name}
limit=32000   # Windows environment variable limit is 32,767 chars; keep a margin
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

set_secret() {   # name file [env]
  local name=$1 file=$2 env=${3:-} size
  size=$(stat -c %s "$file")
  printf '%-18s %-10s %6d bytes ' "$name" "${env:-(repo)}" "$size"
  if (( size > limit )); then echo "FAIL: over $limit"; exit 1; fi
  if [[ -n $env ]]; then "$gh" secret set "$name" --repo "$repo" --env "$env" < "$file"
  else "$gh" secret set "$name" --repo "$repo" < "$file"; fi
  echo "set"
}

k=_testkeys
# Every shared key is stored as base64 of the exact file bytes: raw text secrets
# lose their trailing newline (REPORT.md). The size check applies to the base64 value.
b64() { base64 -w0 "$k/$2" > "$tmp/$1.b64"; set_secret "$1" "$tmp/$1.b64"; }
b64 KEY_SFTP_PRIVATE sftp_rsa
b64 KEY_PGP_PRIVATE  pgp_private.asc
b64 KEY_PGP_PUBLIC   pgp_public.asc
b64 KEY_APNS_P8      apns.p8
b64 KEY_LEGACY_P12   legacy.p12

for t in carecorp initech; do
  "$gh" api -X PUT "repos/$repo/environments/$t" --silent
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-tenant-keys.ps1 -Folder "$k/tenants/$t" > "$tmp/$t.b64"
  set_secret TENANT_KEYS "$tmp/$t.b64" "$t"
done

"$gh" variable set TENANTS_WITH_CUSTOM_KEYS --repo "$repo" --body '["carecorp","initech"]'
echo "TENANTS_WITH_CUSTOM_KEYS set"
