<#
.SYNOPSIS
    Extracts the tenant's own keys from $env:TENANT_KEYS (base64 zip) over <ConfigDir>\<Tenant>\Keys\.
.DESCRIPTION
    Runs after write-shared-keys.ps1; a file with the same name as a shared key replaces it.
    Exits 1 when TENANT_KEYS is empty (no environment, or the environment has no secret).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigDir,
    [Parameter(Mandatory = $true)][string] $Tenant
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($env:TENANT_KEYS)) {
    Write-Host "::error::TENANT_KEYS is empty for tenant '$Tenant' - the job needs 'environment: $Tenant' and that environment needs a TENANT_KEYS secret"
    exit 1
}
try { $bytes = [Convert]::FromBase64String($env:TENANT_KEYS) }
catch [FormatException] { Write-Host "::error::TENANT_KEYS for '$Tenant' is not valid base64"; exit 1 }

$keysDir = Join-Path (Join-Path $ConfigDir $Tenant) 'Keys'
if (-not (Test-Path -LiteralPath $keysDir)) {
    Write-Host "::error::$keysDir does not exist - shared keys must be written first (deploy-all)"
    exit 1
}

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
        $dest = Join-Path $keysDir $entry.Name
        $note = if (Test-Path -LiteralPath $dest) { ' (replaces shared)' } else { '' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        Write-Host ("{0,-10} {1,-28} <- TENANT_KEYS{2}" -f $Tenant, $entry.Name, $note)
    }
    Write-Host "Wrote $($archive.Entries.Count) tenant key file(s) to $keysDir"
}
finally {
    $archive.Dispose()
}
