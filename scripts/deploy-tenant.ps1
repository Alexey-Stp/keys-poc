<#
.SYNOPSIS
    Deploys one tenant on one "server": mirror app, shared + tenant keys, merge, robocopy check, start pool.
.DESCRIPTION
    Shared by deploy-to-all.yml (deploy-all, per tenant) and deploy-to-tenant.yml. Layout under -ServerDir:
        config\<tenant>\Keys\   final keys (CONFIG_DIR in production, outside the app folder)
        <tenant>\app\           mirrored build, never holds keys
    Tenant keys are either already in config\<tenant>\Keys\tenant\ (deploy-to-tenant: write-tenant-keys.ps1)
    or copied there from -TenantKeysFrom (deploy-all: the deploy-tenant-keys artifact).
    Reads the KEY_* variables via write-shared-keys.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ServerDir,
    [Parameter(Mandatory = $true)][string] $Tenant,
    [Parameter(Mandatory = $true)][string] $BuildDir,
    [string] $TenantKeysFrom
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Mirror([string] $From, [string] $To) {
    robocopy $From $To /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To failed (exit $LASTEXITCODE)" }
    $global:LASTEXITCODE = 0   # 0-7 are success codes
}
function Get-KeyHashes([string] $Dir) {
    $h = @{}
    Get-ChildItem -LiteralPath $Dir -File | ForEach-Object { $h[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    return $h
}

$configDir = Join-Path $ServerDir 'config'
$keysDir = Join-Path (Join-Path $configDir $Tenant) 'Keys'
$appDir = Join-Path (Join-Path $ServerDir $Tenant) 'app'

Write-Host "--- $Tenant"
Invoke-Mirror $BuildDir $appDir

& (Join-Path $PSScriptRoot 'write-shared-keys.ps1') -ConfigDir $configDir -Tenant $Tenant
if ($TenantKeysFrom) {
    $files = @(Get-ChildItem -LiteralPath $TenantKeysFrom -File)
    if ($files.Count -eq 0) { throw "No key files directly in $TenantKeysFrom" }
    $tenantDir = Join-Path $keysDir 'tenant'
    New-Item -ItemType Directory -Path $tenantDir -Force | Out-Null
    $files | Copy-Item -Destination $tenantDir -Force
}
& (Join-Path $PSScriptRoot 'merge-keys.ps1') -ConfigDir $configDir -Tenant $Tenant

# Next deploy's mirror of the app folder must not touch the keys (they live in CONFIG_DIR)
$before = Get-KeyHashes $keysDir
Invoke-Mirror $BuildDir $appDir
$after = Get-KeyHashes $keysDir
$changed = @($before.Keys | Where-Object { $after[$_] -ne $before[$_] }) + @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
if ($changed.Count -gt 0) { throw "robocopy /MIR changed key files for '$Tenant': $($changed -join ', ')" }
$msg = "robocopy check ${Tenant}: second /MIR of the app folder left all $($before.Count) key files unchanged"
Write-Host $msg
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "- $msg`n") }

# "Start the app pool" only now that the merged keys are in place
[IO.File]::WriteAllText((Join-Path $appDir 'app-pools-started.txt'), [DateTime]::UtcNow.ToString('o'))
Write-Host "app pool for '$Tenant' started"
