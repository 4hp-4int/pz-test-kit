<#
.SYNOPSIS
    PZ Test Kit — run tests for a PZ Build 42 mod on PZ's actual Kahlua VM.

.DESCRIPTION
    Auto-compiles Java sources on first run or when they change, then invokes
    the Kahlua test runner. Defaults to the current directory as mod root.

.EXAMPLE
    pztest.ps1
    # Runs all tests in the current mod directory.

.EXAMPLE
    pztest.ps1 C:\Mods\MyMod
    # Explicit mod root, auto-discover tests.

.EXAMPLE
    pztest.ps1 C:\Mods\MyMod -- media/lua/client/MyMod/Tests/foo.lua
    # Run a specific test file.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args = @()
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kahluaDir = Join-Path $scriptDir 'kahlua'
$jar       = Join-Path $kahluaDir 'kahlua-runtime.jar'
$stubs     = Join-Path $kahluaDir 'stubs'

if (-not (Test-Path $jar)) {
    Write-Error "pz-test-kit: cannot find $jar"
    Write-Error "pz-test-kit: did you clone the repo with LFS or extract the release zip?"
    exit 1
}

$sources = @('TestPlatform', 'KahluaTestRunner', 'DualVMSim', 'StubbingClassLoader', 'PZTestKitLauncher')

$needCompile = $false
foreach ($src in $sources) {
    $srcFile   = Join-Path $kahluaDir "$src.java"
    $classFile = Join-Path $kahluaDir "$src.class"
    if (Test-Path $srcFile) {
        if ((-not (Test-Path $classFile)) -or
            ((Get-Item $srcFile).LastWriteTime -gt (Get-Item $classFile).LastWriteTime)) {
            $needCompile = $true
            break
        }
    }
}

if ($needCompile) {
    Write-Host '[pztest] compiling Java sources...' -ForegroundColor DarkGray
    Push-Location $kahluaDir
    try {
        $srcFiles = $sources | ForEach-Object { "$_.java" }
        & javac -cp $jar @srcFiles
        if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
    } finally {
        Pop-Location
    }
}

if ($Args.Count -ge 1 -and $Args[0] -eq 'init') {
    $target = (Get-Location).Path
    $configPath = Join-Path $target 'pz-test.lua'
    if (Test-Path $configPath) {
        Write-Error "[pztest] $configPath already exists; refusing to overwrite."
        exit 1
    }
    $modName = Split-Path -Leaf $target
    New-Item -ItemType Directory -Force -Path (Join-Path $target 'tests') | Out-Null

    @"
-- pz-test-kit configuration for $modName
-- See https://github.com/4hp-4int/pz-test-kit for the full schema.
return {
    preload = {
        -- "$modName/Core",
    },
    sandbox = {
        -- $modName = { EnableMod = true },
    },
    -- extra_scripts    = { "weapon_scripts.lua" },
    -- test_file_excludes = { "LegacyHub.lua" },
    -- strict_mocks     = true,
}
"@ | Out-File -Encoding utf8 $configPath

    @"
-- Starter test — delete or replace with your own.
local Assert = PZTestKit.Assert
local tests = {}

tests["example_truthy"] = function()
    return Assert.isTrue(1 + 1 == 2, "math still works")
end

return tests
"@ | Out-File -Encoding utf8 (Join-Path $target 'tests\test_example.lua')

    Write-Host "[pztest] scaffolded $configPath + tests/test_example.lua"
    Write-Host "[pztest] run 'pztest' from this directory to try it."
    exit 0
}

$cpsep     = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }
$classpath = "$jar$cpsep$stubs$cpsep$kahluaDir"

# KahluaTestRunner resolves kahlua/ dir via cwd. cd into the kit's kahlua
# directory first; the mod-root arg is absolute so discovery still works.
$cwd = (Get-Location).Path
Push-Location $kahluaDir
try {
    if ($Args.Count -eq 0 -or $Args[0].StartsWith('-')) {
        $jvmArgs = @($cwd) + $Args
    } elseif (Test-Path -LiteralPath $Args[0] -PathType Container) {
        $jvmArgs = $Args
    } else {
        $jvmArgs = @($cwd) + $Args
    }
    & java -cp $classpath PZTestKitLauncher @jvmArgs
} finally {
    Pop-Location
}
exit $LASTEXITCODE
