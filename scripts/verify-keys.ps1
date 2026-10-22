<#
.SYNOPSIS
    Checks every tenant's Keys\ folder against the expected SHA256 values in hashes.json.
.DESCRIPTION
    For each tenant in hashes.json "expected" (or only -Tenant), finds <ConfigDir>\<tenant>\Keys
    in one of the -ConfigDir folders and compares the exact file set and each file's SHA256.
    Text files must not start with a UTF-8 BOM (EF BB BF). Prints a table (and appends it as
    Markdown to -SummaryPath when given); exits 1 on any problem.
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
$expectedAll = (Get-Content -Raw -LiteralPath $Expected | ConvertFrom-Json).expected
$tenants = if ($Tenant) { $Tenant } else { @($expectedAll.PSObject.Properties.Name) }

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row($t, $file, $status, $detail) {
    $rows.Add([pscustomobject]@{ Tenant = $t; File = $file; Status = $status; Detail = $detail })
}

foreach ($t in $tenants) {
    $exp = $expectedAll.$t
    if ($null -eq $exp) { Add-Row $t '-' 'FAIL' 'tenant not in hashes.json'; continue }

    $found = @($ConfigDir | ForEach-Object { Join-Path (Join-Path $_ $t) 'Keys' } | Where-Object { Test-Path -LiteralPath $_ })
    if ($found.Count -ne 1) { Add-Row $t '-' 'FAIL' "Keys folder found $($found.Count) times (expected 1)"; continue }
    $keysDir = $found[0]

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
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object Status -ne 'OK').Count

if ($SummaryPath) {
    $md = New-Object Text.StringBuilder
    [void]$md.AppendLine("### Key verification: $(if ($failed) { "$failed problem(s)" } else { 'all OK' })")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Tenant | File | Status | Detail |')
    [void]$md.AppendLine('|---|---|---|---|')
    foreach ($r in $rows) { [void]$md.AppendLine("| $($r.Tenant) | $($r.File) | $($r.Status) | $($r.Detail) |") }
    [IO.File]::AppendAllText($SummaryPath, $md.ToString())
}

if ($failed) { Write-Host "::error::$failed key file problem(s)"; exit 1 }
Write-Host "All $($rows.Count) key files match"
