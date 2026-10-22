<#
.SYNOPSIS
    Extracts the tenant's own keys from $env:TENANT_KEYS (base64 zip) into <ConfigDir>\<Tenant>\Keys\tenant\.
.DESCRIPTION
    merge-keys.ps1 later copies them over the shared keys (same name replaces).
    Exits 1 when TENANT_KEYS is empty, unless -Optional (single-tenant deploy of a tenant
    without its own keys), which then writes nothing and exits 0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigDir,
    [Parameter(Mandatory = $true)][string] $Tenant,
    [switch] $Optional
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($env:TENANT_KEYS)) {
    if ($Optional) {
        Write-Host "TENANT_KEYS is empty for tenant '$Tenant' - no tenant keys, shared keys only"
        exit 0
    }
    Write-Host "::error::TENANT_KEYS is empty for tenant '$Tenant' - the job needs 'environment: $Tenant' and that environment needs a TENANT_KEYS secret"
    exit 1
}
try { $bytes = [Convert]::FromBase64String($env:TENANT_KEYS) }
catch [FormatException] { Write-Host "::error::TENANT_KEYS for '$Tenant' is not valid base64"; exit 1 }

$tenantDir = Join-Path (Join-Path (Join-Path $ConfigDir $Tenant) 'Keys') 'tenant'
if (Test-Path -LiteralPath $tenantDir) { Remove-Item -LiteralPath $tenantDir -Recurse -Force }
New-Item -ItemType Directory -Path $tenantDir -Force | Out-Null

$archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.ZipArchiveMode]::Read)
try {
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($entry in $archive.Entries) {
        # plain file names only: no folders, no ..\ escapes
        if ($entry.FullName -ne $entry.Name -or $entry.Name -eq '' -or $entry.Name.IndexOfAny($invalid) -ge 0) {
            Write-Host "::error::TENANT_KEYS for '$Tenant' contains '$($entry.FullName)' - only plain file names are allowed"
            exit 1
        }
    }
    foreach ($entry in $archive.Entries) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $tenantDir $entry.Name), $true)
        Write-Host ("{0,-10} {1,-28} <- TENANT_KEYS" -f $Tenant, "tenant\$($entry.Name)")
    }
    Write-Host "Wrote $($archive.Entries.Count) tenant key file(s) to $tenantDir"
}
finally {
    $archive.Dispose()
}
