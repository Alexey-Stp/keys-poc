<#
.SYNOPSIS
    Writes key files from KEYFILE_* environment variables (ENG-2521 PoC).
.DESCRIPTION
    Each variable is KEYFILE_<SCOPE>__<file name> = single-line base64 of the file content.
    SCOPE is GLOBAL (every tenant) or the tenant token (that tenant only). A tenant file with
    the same name as a GLOBAL one replaces it. No file names are hard-coded.
    Only variable and file names are printed, never values.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $TenantName,
    [string] $OutputDir = 'output-keys'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KeyFileEnvPrefix = 'KEYFILE_'

# prod:carecorp1 -> CARECORP1, fls2dotnet -> FLS2DOTNET
function ConvertTo-KeyTenantName {
    param([Parameter(Mandatory = $true)][string] $Name)
    return (($Name -replace '^prod:', '').ToUpperInvariant() -replace '[^A-Z0-9]', '_')
}

$token = ConvertTo-KeyTenantName -Name $TenantName
if ($token -eq 'GLOBAL') { throw "Tenant name '$TenantName' is reserved" }

$scopes = @(
    @{ Scope = 'GLOBAL'; Prefix = "${KeyFileEnvPrefix}GLOBAL__" },   # first, so tenant entries override
    @{ Scope = $token;   Prefix = "${KeyFileEnvPrefix}${token}__" }
)
$invalidChars = [IO.Path]::GetInvalidFileNameChars()
$allKeyVars = @(Get-ChildItem Env: | Where-Object { $_.Name.StartsWith($KeyFileEnvPrefix, [StringComparison]::OrdinalIgnoreCase) })

$files = [ordered]@{}   # file name (case-insensitive, like NTFS) -> entry
$counts = @{ GLOBAL = 0; Tenant = 0 }
foreach ($s in $scopes) {
    $vars = @($allKeyVars | Where-Object { $_.Name.StartsWith($s.Prefix, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Name)
    foreach ($var in $vars) {
        $fileName = $var.Name.Substring($s.Prefix.Length)
        if ($fileName -eq '' -or $fileName -eq '.' -or $fileName -eq '..' -or $fileName.IndexOfAny($invalidChars) -ge 0) {
            throw "$($var.Name): '$fileName' is not a plain file name"
        }
        if ([string]::IsNullOrWhiteSpace($var.Value)) {
            throw "$($var.Name) is empty - is its secret set?"
        }
        try { $bytes = [Convert]::FromBase64String($var.Value) }
        catch [FormatException] { throw "$($var.Name) is not valid base64" }

        $files[$fileName] = [pscustomobject]@{
            Scope     = $s.Scope
            Variable  = $var.Name
            Bytes     = $bytes
            Overrides = $files.Contains($fileName)
        }
        if ($s.Scope -eq 'GLOBAL') { $counts.GLOBAL++ } else { $counts.Tenant++ }
    }
}
if ($counts.GLOBAL -eq 0) { throw "No ${KeyFileEnvPrefix}GLOBAL__* variables found - are the secrets mapped in the step env?" }

# Fresh folder each run, like the real deploy (XML\Keys is purged with the old build)
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Recurse -Force }
New-Item -ItemType Directory -Path $outPath | Out-Null

foreach ($name in $files.Keys) {
    $entry = $files[$name]
    [IO.File]::WriteAllBytes((Join-Path $outPath $name), $entry.Bytes)
    $note = if ($entry.Overrides) { ' (replaces GLOBAL)' } else { '' }
    Write-Host ("{0,-10} {1,-28} <- {2}{3}" -f $entry.Scope, $name, $entry.Variable, $note)
}
$ignored = $allKeyVars.Count - $counts.GLOBAL - $counts.Tenant
Write-Host "Wrote $($files.Count) key file(s) to $outPath for '$TenantName': $($counts.GLOBAL) global + $($counts.Tenant) tenant; ignored $ignored variable(s) of other tenants"
