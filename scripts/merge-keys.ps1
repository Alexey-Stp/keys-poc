<#
.SYNOPSIS
    Builds the final <ConfigDir>\<Tenant>\Keys\ from Keys\shared\ and Keys\tenant\, then removes both.
.DESCRIPTION
    Replaces the files in Keys\ with shared\*, then tenant\* on top (same name replaces shared).
    Merged files get the current time as LastWriteTime, so verify-keys.ps1 can prove the app
    pool was started after the keys were in place (a plain copy would keep the old times).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigDir,
    [Parameter(Mandatory = $true)][string] $Tenant
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$keysDir = Join-Path (Join-Path $ConfigDir $Tenant) 'Keys'
$sharedDir = Join-Path $keysDir 'shared'
$tenantDir = Join-Path $keysDir 'tenant'

foreach ($d in @($sharedDir, $tenantDir)) {
    if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Directory).Count -gt 0) {
        throw "$d contains subfolders - key files must be directly in it"
    }
}
$shared = @(if (Test-Path -LiteralPath $sharedDir) { Get-ChildItem -LiteralPath $sharedDir -File })
if ($shared.Count -eq 0) { throw "No shared keys in $sharedDir - write-shared-keys.ps1 must run first" }
$tenantFiles = @(if (Test-Path -LiteralPath $tenantDir) { Get-ChildItem -LiteralPath $tenantDir -File })

Get-ChildItem -LiteralPath $keysDir -File | Remove-Item -Force
$merged = @{}
foreach ($f in $shared) { Copy-Item -LiteralPath $f.FullName -Destination $keysDir; $merged[$f.Name] = 'shared' }
foreach ($f in $tenantFiles) {
    $note = if ($merged.ContainsKey($f.Name)) { 'tenant (replaces shared)' } else { 'tenant' }
    Copy-Item -LiteralPath $f.FullName -Destination $keysDir -Force
    $merged[$f.Name] = $note
}

$now = [DateTime]::UtcNow
foreach ($name in $merged.Keys | Sort-Object) {
    [IO.File]::SetLastWriteTimeUtc((Join-Path $keysDir $name), $now)
    Write-Host ("{0,-10} {1,-28} <- {2}" -f $Tenant, $name, $merged[$name])
}
Remove-Item -LiteralPath $sharedDir -Recurse -Force
if (Test-Path -LiteralPath $tenantDir) { Remove-Item -LiteralPath $tenantDir -Recurse -Force }
Write-Host "Merged $($merged.Count) key file(s) into $keysDir ($($shared.Count) shared, $($tenantFiles.Count) tenant)"
