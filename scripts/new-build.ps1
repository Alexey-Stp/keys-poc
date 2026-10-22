<#
.SYNOPSIS
    "Builds" the app once for a server: <ServerDir>\build\app.txt with a timestamp. Returns the build folder.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ServerDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$build = Join-Path $ServerDir 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $build 'app.txt'), "built for $(Split-Path $ServerDir -Leaf) at $([DateTime]::UtcNow.ToString('o'))")
return $build
