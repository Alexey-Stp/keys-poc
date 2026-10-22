<#
.SYNOPSIS
    Checks every tenant's final Keys\ folder and app folder against hashes.json.
.DESCRIPTION
    -ConfigDir is a server's config folder (CONFIG_DIR); the tenant's app folder is the sibling
    <server>\<tenant>\app. For each tenant in hashes.json "expected" (or only -Tenant):
      - Keys\ holds exactly the expected files, each with the expected SHA256
      - text files don't start with a UTF-8 BOM (EF BB BF)
      - Keys\ has no subfolders left (shared\, tenant\)
      - no key file anywhere under <tenant>\app\
      - <tenant>\app\app-pools-started.txt exists and is not older than the newest key file
    Prints a table (and appends it as Markdown to -SummaryPath when given); exits 1 on any problem.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]] $ConfigDir,
    [Parameter(Mandatory = $true)][string] $Expected,
    [string[]] $Tenant,
    [string] $SummaryPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binaryExtensions = @('.p12', '.pfx')
$keyExtensions = @('.openssh', '.pgp', '.gpg', '.asc', '.p8', '.p12', '.pfx', '.pem', '.ppk', '.key')
$expectedAll = (Get-Content -Raw -LiteralPath $Expected | ConvertFrom-Json).expected
$tenants = if ($Tenant) { $Tenant } else { @($expectedAll.PSObject.Properties.Name) }

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row($t, $file, $status, $detail) {
    $rows.Add([pscustomobject]@{ Tenant = $t; File = $file; Status = $status; Detail = $detail })
}

foreach ($t in $tenants) {
    $exp = $expectedAll.$t
    if ($null -eq $exp) { Add-Row $t '-' 'FAIL' 'tenant not in hashes.json'; continue }

    $found = @($ConfigDir | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $_ $t) 'Keys') })
    if ($found.Count -ne 1) { Add-Row $t '-' 'FAIL' "Keys folder found $($found.Count) times (expected 1)"; continue }
    $keysDir = Join-Path (Join-Path $found[0] $t) 'Keys'
    $appDir = Join-Path (Join-Path (Split-Path -Parent $found[0]) $t) 'app'

    # --- key files
    $expNames = @($exp.PSObject.Properties.Name)
    $actual = @(Get-ChildItem -LiteralPath $keysDir -File -Force)
    foreach ($f in $actual | Sort-Object Name) {
        if ($expNames -notcontains $f.Name) { Add-Row $t $f.Name 'FAIL' 'unexpected file'; continue }

        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $problems = @()
        # Line endings are informational: some sources are CRLF on purpose, and any change shows as a hash mismatch
        $kind = 'binary'
        if ($binaryExtensions -notcontains $f.Extension.ToLowerInvariant()) {
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $problems += 'BOM' }
            $kind = if ([Array]::IndexOf($bytes, [byte]13) -ge 0) { 'CRLF' } else { 'LF' }
        }
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        if ($hash -ne $exp.($f.Name)) { $problems += 'hash mismatch' }

        if ($problems.Count -eq 0) { Add-Row $t $f.Name 'OK' "$($bytes.Length) bytes, $kind" }
        else { Add-Row $t $f.Name 'FAIL' ("$($bytes.Length) bytes, ${kind}: " + ($problems -join ', ')) }
    }
    foreach ($n in $expNames | Sort-Object) {
        if (@($actual | Where-Object Name -eq $n).Count -eq 0) { Add-Row $t $n 'FAIL' 'missing' }
    }

    # --- layout
    $subDirs = @(Get-ChildItem -LiteralPath $keysDir -Directory -Force | ForEach-Object Name)
    if ($subDirs.Count -gt 0) { Add-Row $t '(Keys subfolders)' 'FAIL' "left after merge: $($subDirs -join ', ')" }
    else { Add-Row $t '(Keys subfolders)' 'OK' 'none' }

    if (-not (Test-Path -LiteralPath $appDir)) { Add-Row $t '(app folder)' 'FAIL' "missing: $appDir"; continue }
    $keysInApp = @(Get-ChildItem -LiteralPath $appDir -File -Recurse -Force | Where-Object {
            $expNames -contains $_.Name -or $keyExtensions -contains $_.Extension.ToLowerInvariant() })
    if ($keysInApp.Count -gt 0) { Add-Row $t '(app folder)' 'FAIL' ("key files in app: " + (($keysInApp | ForEach-Object Name) -join ', ')) }
    else { Add-Row $t '(app folder)' 'OK' 'no key files' }

    $pools = Join-Path $appDir 'app-pools-started.txt'
    if (-not (Test-Path -LiteralPath $pools)) { Add-Row $t '(app pool start)' 'FAIL' 'app-pools-started.txt missing' }
    elseif ($actual.Count -gt 0) {
        $newestKey = ($actual | Sort-Object LastWriteTimeUtc -Descending)[0].LastWriteTimeUtc
        $started = (Get-Item -LiteralPath $pools).LastWriteTimeUtc
        $detail = "pool $($started.ToString('HH:mm:ss.fff')), newest key $($newestKey.ToString('HH:mm:ss.fff'))"
        if ($started -lt $newestKey) { Add-Row $t '(app pool start)' 'FAIL' "pool started before keys were in place: $detail" }
        else { Add-Row $t '(app pool start)' 'OK' $detail }
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($rows | Where-Object Status -ne 'OK').Count
$keyRows = @($rows | Where-Object { $_.File -notlike '(*' })
$keyOk = @($keyRows | Where-Object Status -eq 'OK').Count
$headline = "$keyOk/$($keyRows.Count) key files byte-exact; $failed problem(s)"

if ($SummaryPath) {
    $md = New-Object Text.StringBuilder
    [void]$md.AppendLine("### Key verification: $headline")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Tenant | File / check | Status | Detail |')
    [void]$md.AppendLine('|---|---|---|---|')
    foreach ($r in $rows) { [void]$md.AppendLine("| $($r.Tenant) | $($r.File) | $($r.Status) | $($r.Detail) |") }
    [IO.File]::AppendAllText($SummaryPath, $md.ToString())
}

Write-Host $headline
if ($failed) { Write-Host "::error::$failed problem(s)"; exit 1 }
