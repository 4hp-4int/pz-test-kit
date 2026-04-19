param(
    [string]$ModPath = "$env:USERPROFILE\Zomboid\mods"
)

$ErrorActionPreference = "Stop"
$Source = Join-Path (Split-Path -Parent $PSScriptRoot) "examples\MyMod"
$Dest = Join-Path $ModPath "MyModExample"

if (-not (Test-Path "$Source\mod.info")) {
    Write-Error "Cannot find examples\MyMod"
    exit 1
}

Write-Host "Deploying MyMod example to $Dest"

if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }

# PZ B42 mod structure: common/mod.info + 42.0/media/...
$commonDir = Join-Path $Dest "common"
$versionDir = Join-Path $Dest "42.0"

New-Item -ItemType Directory -Path $commonDir -Force | Out-Null
New-Item -ItemType Directory -Path $versionDir -Force | Out-Null

Copy-Item -Force "$Source\mod.info" $commonDir
Copy-Item -Recurse -Force "$Source\media" $versionDir

$count = (Get-ChildItem -Recurse -File $Dest).Count
Write-Host "Deployed $count files"
Write-Host ""
Write-Host "Next: Launch PZ, enable MyMod Example, open Lua console, run:"
Write-Host '  PZTestKit.runTests()'
