<#
.SYNOPSIS
    Writes the shared keys from KEY_* environment variables to <ConfigDir>\<Tenant>\Keys\.
.DESCRIPTION
    Text keys are written byte-for-byte as UTF-8 without a BOM and nothing appended.
    KEY_LEGACY_P12 holds base64 of a binary file and is decoded. Prints names, never values.
    -Broken writes text with Set-Content instead (BOM + CRLF) - used by negative.yml only.
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
$base64Keys = @('KEY_LEGACY_P12')

$keysDir = Join-Path (Join-Path $ConfigDir $Tenant) 'Keys'
New-Item -ItemType Directory -Path $keysDir -Force | Out-Null
$utf8NoBom = New-Object Text.UTF8Encoding($false)

foreach ($var in $sharedKeys.Keys) {
    $value = [Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrEmpty($value)) { throw "$var is empty - is the repository secret set and mapped in the step env?" }
    $path = Join-Path $keysDir $sharedKeys[$var]

    if ($base64Keys -contains $var) {
        try { $bytes = [Convert]::FromBase64String($value) }
        catch [FormatException] { throw "$var is not valid base64" }
        [IO.File]::WriteAllBytes($path, $bytes)
    }
    elseif ($Broken) {
        Set-Content -LiteralPath $path -Value $value -Encoding UTF8   # deliberately wrong: BOM + CRLF
    }
    else {
        [IO.File]::WriteAllText($path, $value, $utf8NoBom)
    }
    Write-Host ("{0,-10} {1,-28} <- {2}" -f $Tenant, $sharedKeys[$var], $var)
}
