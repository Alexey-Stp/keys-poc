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
set_secret KEY_SFTP_PRIVATE "$k/sftp_rsa"
set_secret KEY_PGP_PRIVATE  "$k/pgp_private.asc"
set_secret KEY_PGP_PUBLIC   "$k/pgp_public.asc"
set_secret KEY_APNS_P8      "$k/apns.p8"
base64 -w0 "$k/legacy.p12" > "$tmp/legacy.p12.b64"
set_secret KEY_LEGACY_P12   "$tmp/legacy.p12.b64"

for t in carecorp initech; do
  "$gh" api -X PUT "repos/$repo/environments/$t" --silent
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-tenant-keys.ps1 -Folder "$k/tenants/$t" > "$tmp/$t.b64"
  set_secret TENANT_KEYS "$tmp/$t.b64" "$t"
done

"$gh" variable set TENANTS_WITH_CUSTOM_KEYS --repo "$repo" --body '["carecorp","initech"]'
echo "TENANTS_WITH_CUSTOM_KEYS set"
