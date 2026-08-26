param(
    [string]$PZDir = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [string]$JdkHome = $null,
    [string]$Release = "17"
)

# Builds the pz-shell ZombieBuddy agent: one class that re-exposes
# LuaCompiler.loadstring as a Lua global, which PZ's 2026-08 security patch
# withdrew (it stopped calling LuaCompiler.register; the compiler itself is
# untouched). Mirrors VPSFx/build.ps1 -- same javac+jar shape, same layout.
#
# Output lands in the pz-shell MOD's media/java/shared/, which is where
# ZombieBuddy picks agent jars up from.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

$pzJar = Join-Path $PZDir "projectzomboid.jar"
$zbJar = Join-Path $PZDir "ZombieBuddy.jar"

if (-not (Test-Path $pzJar)) { throw "projectzomboid.jar not found at $pzJar" }
if (-not (Test-Path $zbJar)) { throw "ZombieBuddy.jar not found at $zbJar (install ZombieBuddy first)" }

# Oracle's javapath shim has no jar.exe, so reach into a real JDK.
if (-not $JdkHome) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\jar.exe"))) {
        $JdkHome = $env:JAVA_HOME
    } else {
        $candidate = Get-ChildItem "C:\Program Files\Java" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\jar.exe") } |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $candidate) { throw "No JDK with jar.exe found under C:\Program Files\Java\. Set -JdkHome or JAVA_HOME." }
        $JdkHome = $candidate.FullName
    }
}
$javac = Join-Path $JdkHome "bin\javac.exe"
$jarExe = Join-Path $JdkHome "bin\jar.exe"
if (-not (Test-Path $javac))  { throw "javac.exe not found at $javac" }
if (-not (Test-Path $jarExe)) { throw "jar.exe not found at $jarExe" }

$srcDir    = Join-Path $root "src"
$outDir    = Join-Path $root "out\classes"
$jarOutDir = Join-Path $root "..\mod\media\java\shared"
$jarOut    = Join-Path $jarOutDir "PZShellAgent.jar"

Write-Host "pz-shell agent build" -ForegroundColor Cyan
Write-Host "  JDK     : $JdkHome"
Write-Host "  PZ      : $pzJar"
Write-Host "  ZB      : $zbJar"
Write-Host "  out jar : $jarOut"

if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path $jarOutDir | Out-Null

$classpath = "$pzJar;$zbJar"
$sources = Get-ChildItem -Path $srcDir -Filter *.java -Recurse | Select-Object -ExpandProperty FullName

Write-Host "`nCompiling $($sources.Count) source file(s) (--release $Release)..." -ForegroundColor Yellow
& $javac --release $Release -encoding UTF-8 -cp $classpath -d $outDir $sources
if ($LASTEXITCODE -ne 0) { throw "javac failed (exit $LASTEXITCODE)" }

Write-Host "Packaging jar..." -ForegroundColor Yellow
& $jarExe --create --file $jarOut -C $outDir .
if ($LASTEXITCODE -ne 0) { throw "jar failed (exit $LASTEXITCODE)" }

$jarSize = (Get-Item $jarOut).Length
Write-Host "`nBuilt: $jarOut ($jarSize bytes)" -ForegroundColor Green
