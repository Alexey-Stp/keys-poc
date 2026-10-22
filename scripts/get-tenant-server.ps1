<#
.SYNOPSIS
    Returns the server that hosts -Tenant according to tenants.json; throws unless exactly one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Tenant,
    [string] $TenantsFile = (Join-Path $PSScriptRoot '..\tenants.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$servers = Get-Content -Raw -LiteralPath $TenantsFile | ConvertFrom-Json
$found = @($servers.PSObject.Properties | Where-Object { @($_.Value) -contains $Tenant } | ForEach-Object Name)
if ($found.Count -ne 1) { throw "Tenant '$Tenant' is listed on $($found.Count) servers in tenants.json (expected 1)" }
return $found[0]
