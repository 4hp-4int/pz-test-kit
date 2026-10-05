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

$sources = @('TestPlatform', 'KahluaTestRunner', 'DualVMSim', 'StubbingClassLoader', 'PZTestKitLauncher', 'ScriptCheck', 'EngineBridge', 'PzLocator')

# Compile into a build directory named for the sources' content, never in
# place (same scheme and same hash as the bash pztest): a long-lived
# dashboard VM keeps loading classes lazily, and rewriting kahlua/*.class
# under it left it half old, half new. A build dir is written once, to a
# temp name renamed into place, and never touched again.
$buildRoot = Join-Path $kahluaDir '.build'
$ms = New-Object System.IO.MemoryStream
foreach ($src in $sources) {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $kahluaDir "$src.java"))
    $ms.Write($b, 0, $b.Length)
}
$sha = [System.Security.Cryptography.SHA1]::Create()
$srcHash = (($sha.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
$buildDir = Join-Path $buildRoot $srcHash

if (-not (Test-Path (Join-Path $buildDir '.complete'))) {
    Write-Host "[pztest] compiling Java sources -> .build/$srcHash" -ForegroundColor DarkGray
    New-Item -ItemType Directory -Force $buildRoot | Out-Null
    $tmpBuild = Join-Path $buildRoot ".tmp-$srcHash-$PID"
    if (Test-Path $tmpBuild) { Remove-Item -Recurse -Force $tmpBuild }
    New-Item -ItemType Directory -Force $tmpBuild | Out-Null
    Push-Location $kahluaDir
    try {
        $srcFiles = $sources | ForEach-Object { "$_.java" }
        & javac -nowarn -cp $jar -d $tmpBuild @srcFiles
        if ($LASTEXITCODE -ne 0) { Remove-Item -Recurse -Force $tmpBuild; throw 'javac failed' }
    } finally {
        Pop-Location
    }
    New-Item -ItemType File (Join-Path $tmpBuild '.complete') | Out-Null
    if (Test-Path (Join-Path $buildDir '.complete')) { Remove-Item -Recurse -Force $tmpBuild }
    else {
        try { Move-Item $tmpBuild $buildDir -ErrorAction Stop } catch { Remove-Item -Recurse -Force $tmpBuild }
    }
    # Prune builds unused for two days (never the current one).
    Get-ChildItem $buildRoot -Directory | Where-Object { $_.Name -ne $srcHash -and $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
        ForEach-Object { try { Remove-Item -Recurse -Force $_.FullName -ErrorAction Stop } catch {} }
}
try { (Get-Item $buildDir).LastWriteTime = Get-Date } catch {}

# scriptcheck — validate media/scripts/*.txt with PZ's OWN parser.
#
# Separate subcommand rather than part of the test run: it needs no mod config,
# no Lua, and no test files, so it can run on a mod that has no suite at all,
# and it is the cheapest possible CI gate (parses ~1000 files in under a
# second). See kahlua/ScriptCheck.java for what it checks and why.
if ($Args.Count -ge 1 -and $Args[0] -eq 'scriptcheck') {
    $targets = @($Args[1..($Args.Count - 1)] | Where-Object { $_ })
    if ($targets.Count -eq 0) {
        $default = Join-Path (Get-Location).Path 'media/scripts'
        if (-not (Test-Path $default)) {
            Write-Host "[scriptcheck] no media/scripts in $((Get-Location).Path) - nothing to check"
            exit 0
        }
        $targets = @($default)
    }
    & java -cp "$buildDir;$jar;$kahluaDir" ScriptCheck @targets
    exit $LASTEXITCODE
}

# apicheck — do these Lua files call methods PZ actually exposes?
#
# Same shape as scriptcheck and for the same reason: no mod config, no VM, no
# test files, so it runs on a mod with no suite. That is the point -- the bugs
# it targets (an invented Java method, a public Java field Kahlua cannot see, a
# collection walked with iterator()) fail SILENTLY inside a pcall, in adapter
# files nobody wrote a test for. See tools/pz_api_check.py.
if ($Args.Count -ge 1 -and $Args[0] -eq 'apicheck') {
    # NOT $Args[1..($Args.Count-1)]: with one arg that is $Args[1..0], which
    # PowerShell evaluates as a REVERSED range and hands back 'apicheck' itself
    # as a target.
    $targets = if ($Args.Count -ge 2) { @($Args[1..($Args.Count - 1)] | Where-Object { $_ }) } else { @() }
    if ($targets.Count -eq 0 -and -not (Test-Path (Join-Path (Get-Location).Path 'media/lua'))) {
        Write-Host "[apicheck] no media/lua in $((Get-Location).Path) - nothing to check"
        exit 0
    }
    & python (Join-Path $scriptDir 'tools/pz_api_check.py') @targets
    exit $LASTEXITCODE
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
# STUBS FIRST: the runtime jar bakes a copy of every stub at build time and
# the classloader searches in order — jar-first meant an edited stub silently
# lost to its stale baked copy until the jar was rebuilt.
$classpath = "$stubs$cpsep$buildDir$cpsep$jar$cpsep$kahluaDir"

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
