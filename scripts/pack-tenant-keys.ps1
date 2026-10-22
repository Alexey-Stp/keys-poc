<#
.SYNOPSIS
    Packs a tenant's key folder into the TENANT_KEYS secret value: zip -> base64 -> stdout.
.DESCRIPTION
    The folder must hold exactly the files that should land in the tenant's Keys\ folder,
    with their final names (a file named like a shared key replaces it). No subfolders.
.EXAMPLE
    gh secret set TENANT_KEYS --env carecorp --body "$(powershell -File scripts/pack-tenant-keys.ps1 -Folder _testkeys/tenants/carecorp)"
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $Folder)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Folder = (Resolve-Path -LiteralPath $Folder).Path
if (@(Get-ChildItem -LiteralPath $Folder -Directory -Force).Count -gt 0) { throw "$Folder has subfolders - only plain files are allowed" }
if (@(Get-ChildItem -LiteralPath $Folder -File -Force).Count -eq 0) { throw "$Folder has no files" }

$zip = Join-Path ([IO.Path]::GetTempPath()) "tenant-keys-$([guid]::NewGuid()).zip"
try {
    [IO.Compression.ZipFile]::CreateFromDirectory($Folder, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    # No trailing newline, so the value is exactly the base64 text
    [Console]::Out.Write([Convert]::ToBase64String([IO.File]::ReadAllBytes($zip)))
}
finally {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}
