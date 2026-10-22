#!/usr/bin/env bash
# Generates throwaway test keys in _testkeys/ (git-ignored) and _testkeys/hashes.json.
# Run from the repo root in Git Bash. Never use these keys for anything real.
set -euo pipefail

out=_testkeys
rm -rf "$out"
mkdir -p "$out/shared" "$out/tenants/carecorp" "$out/tenants/initech"
export GNUPGHOME="$PWD/$out/.gnupg"   # throwaway keyring, not the user's
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

# --- shared keys (spec file names in _testkeys/, deploy names are chosen by write-shared-keys.ps1)
ssh-keygen -q -t rsa -b 4096 -N "" -C "test-shared" -f "$out/sftp_rsa"
gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key "Test Shared <test@example.com>" rsa4096 default never
gpg --batch --armor --pinentry-mode loopback --passphrase "" --export-secret-keys test@example.com > "$out/pgp_private.asc"
gpg --batch --armor --export test@example.com > "$out/pgp_public.asc"
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$out/apns.p8"
MSYS2_ARG_CONV_EXCL="*" openssl req -x509 -newkey rsa:4096 -nodes -keyout "$out/legacy_key.pem" -out "$out/legacy_cert.pem" -days 30 -subj "/CN=test-legacy" 2>/dev/null
openssl pkcs12 -export -inkey "$out/legacy_key.pem" -in "$out/legacy_cert.pem" -passout pass:test -out "$out/legacy.p12"
rm "$out/legacy_key.pem" "$out/legacy_cert.pem"

# Deploy file name <- source file, for the shared set (must match write-shared-keys.ps1)
declare -A shared=(
  [SSC_SFTPPrivateKey.openSSH]=sftp_rsa
  [PGPPrivateKey.pgp]=pgp_private.asc
  [PGPPublicKey.pgp]=pgp_public.asc
  [AuthKey_APNS.p8]=apns.p8
  [Legacy.p12]=legacy.p12
)

# --- tenant keys: folder content = exactly what lands in Keys\ (same name = replaces shared)
for t in carecorp initech; do
  d="$out/tenants/$t"
  ssh-keygen -q -t rsa -b 4096 -N "" -C "test-$t" -f "$d/SSC_SFTPPrivateKey.openSSH"
  rm "$d/SSC_SFTPPrivateKey.openSSH.pub"
  # partner public key, 5-8 KB: rsa4096 primary + 2 rsa4096 subkeys
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key "Partner $t <partner@$t.example>" rsa4096 default never
  fpr=$(gpg --batch --with-colons --list-keys "partner@$t.example" | awk -F: '/^fpr/{print $10; exit}')
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-add-key "$fpr" rsa4096 encr never
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-add-key "$fpr" rsa4096 sign never
  gpg --batch --armor --export "partner@$t.example" > "$d/partner.asc"
done
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/tenants/carecorp/extra.pem" 2>/dev/null

# --- hashes.json: per-source hashes + expected final Keys\ content per tenant
h() { sha256sum "$1" | awk '{print toupper($1)}'; }
json_map() {   # args: name=path ... -> {"name":"HASH",...}
  local first=1; printf '{'
  for kv in "$@"; do
    [[ $first -eq 1 ]] || printf ','; first=0
    printf '"%s":"%s"' "${kv%%=*}" "$(h "${kv#*=}")"
  done
  printf '}'
}
shared_args=(); for n in "${!shared[@]}"; do shared_args+=("$n=$out/${shared[$n]}"); done

tenant_args() {   # shared set, then the tenant's own files override by name
  declare -A m=(); for n in "${!shared[@]}"; do m[$n]="$out/${shared[$n]}"; done
  if [[ -d "$out/tenants/$1" ]]; then for f in "$out/tenants/$1"/*; do m[$(basename "$f")]="$f"; done; fi
  for n in "${!m[@]}"; do printf '%s\n' "$n=${m[$n]}"; done | sort
}

{
  printf '{\n  "sources": {\n'
  first=1
  while IFS= read -r f; do
    [[ $first -eq 1 ]] || printf ',\n'; first=0
    printf '    "%s": {"bytes": %d, "sha256": "%s"}' "${f#$out/}" "$(stat -c %s "$f")" "$(h "$f")"
  done < <(find "$out" -path "$out/.gnupg" -prune -o -type f ! -name '*.pub' ! -name hashes.json -print | sort)
  printf '\n  },\n  "expected": {\n'
  tenants=(acme carecorp globex initech); last=${#tenants[@]}; i=0
  for t in "${tenants[@]}"; do
    i=$((i+1)); mapfile -t args < <(tenant_args "$t")
    printf '    "%s": %s' "$t" "$(json_map "${args[@]}")"
    [[ $i -lt $last ]] && printf ',\n'
  done
  printf '\n  }\n}\n'
} > "$out/hashes.json"

rm -rf "$GNUPGHOME" "$out/sftp_rsa.pub"
echo "Generated:"; find "$out" -type f | sort | while read -r f; do printf '  %6d  %s\n' "$(stat -c %s "$f")" "$f"; done
