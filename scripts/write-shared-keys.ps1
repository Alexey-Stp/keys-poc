<#
.SYNOPSIS
    Writes the shared keys from KEY_* environment variables to <ConfigDir>\<Tenant>\Keys\shared\.
.DESCRIPTION
    Every KEY_* value is base64 of the exact file bytes; one path for all keys:
    FromBase64String -> WriteAllBytes. Prints names, never values.
    -Broken writes the decoded bytes as a string with Set-Content (BOM + CRLF) - negative.yml only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigDir,
    [Parameter(Mandatory = $true)][string] $Tenant,
    [switch] $Broken
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# environment variable -> file name in Keys\
$sharedKeys = [ordered]@{
    KEY_SFTP_PRIVATE = 'SSC_SFTPPrivateKey.openSSH'
    KEY_PGP_PRIVATE  = 'PGPPrivateKey.pgp'
    KEY_PGP_PUBLIC   = 'PGPPublicKey.pgp'
    KEY_APNS_P8      = 'AuthKey_APNS.p8'
    KEY_LEGACY_P12   = 'Legacy.p12'
}

$sharedDir = Join-Path (Join-Path (Join-Path $ConfigDir $Tenant) 'Keys') 'shared'
if (Test-Path -LiteralPath $sharedDir) { Remove-Item -LiteralPath $sharedDir -Recurse -Force }
New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null

foreach ($var in $sharedKeys.Keys) {
    $value = [Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrEmpty($value)) { throw "$var is empty - is the repository secret set and mapped in the step env?" }
    try { $bytes = [Convert]::FromBase64String($value) }
    catch [FormatException] { throw "$var is not valid base64" }

    $path = Join-Path $sharedDir $sharedKeys[$var]
    if ($Broken) {
        Set-Content -LiteralPath $path -Value ([Text.Encoding]::UTF8.GetString($bytes)) -Encoding UTF8   # deliberately wrong
    }
    else {
        [IO.File]::WriteAllBytes($path, $bytes)
    }
    Write-Host ("{0,-10} {1,-28} <- {2}" -f $Tenant, "shared\$($sharedKeys[$var])", $var)
}
