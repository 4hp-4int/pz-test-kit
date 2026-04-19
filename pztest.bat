@echo off
REM PZ Test Kit — run tests for a PZ Build 42 mod on PZ's actual Kahlua VM.
REM
REM Usage (from mod root):
REM     pztest                        - run all auto-discovered tests
REM     pztest -- path\to\test.lua    - run a specific test file
REM Usage (from elsewhere):
REM     pztest C:\Mods\MyMod

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "KAHLUA_DIR=%SCRIPT_DIR%kahlua"
set "JAR=%KAHLUA_DIR%\kahlua-runtime.jar"
set "STUBS=%KAHLUA_DIR%\stubs"

if not exist "%JAR%" (
    echo pz-test-kit: cannot find %JAR% 1>&2
    echo pz-test-kit: did you clone the repo with LFS or extract the release zip? 1>&2
    exit /b 1
)

REM Compile if any .class is missing. (cmd can't cleanly compare timestamps;
REM if a source changes, delete the .class to force recompile, or use the
REM bash / PowerShell wrappers for automatic recompile detection.)
set "NEED_COMPILE=0"
for %%s in (TestPlatform KahluaTestRunner DualVMSim StubbingClassLoader PZTestKitLauncher) do (
    if exist "%KAHLUA_DIR%\%%s.java" (
        if not exist "%KAHLUA_DIR%\%%s.class" set "NEED_COMPILE=1"
    )
)

if "%NEED_COMPILE%"=="1" (
    echo [pztest] compiling Java sources... 1>&2
    pushd "%KAHLUA_DIR%"
    javac -cp "%JAR%" TestPlatform.java KahluaTestRunner.java DualVMSim.java StubbingClassLoader.java PZTestKitLauncher.java
    if errorlevel 1 (
        popd
        exit /b 1
    )
    popd
)

set "CP=%JAR%;%STUBS%;%KAHLUA_DIR%"
set "ORIG_CWD=%CD%"

REM KahluaTestRunner finds kahlua/ via cwd. cd to the kit's kahlua dir;
REM the mod-root arg is absolute so mod discovery still works.
cd /d "%KAHLUA_DIR%"

REM If no args, use original cwd as mod root.
if "%~1"=="" (
    java -cp "%CP%" PZTestKitLauncher "%ORIG_CWD%"
    exit /b !errorlevel!
)

REM If first arg starts with -, prepend original cwd as mod root.
set "FIRST=%~1"
if "!FIRST:~0,1!"=="-" (
    java -cp "%CP%" PZTestKitLauncher "%ORIG_CWD%" %*
    exit /b !errorlevel!
)

REM If first arg is a directory, use it as mod root.
if exist "%~1\" (
    java -cp "%CP%" PZTestKitLauncher %*
    exit /b !errorlevel!
)

REM Else (probably a test-file path), prepend original cwd.
java -cp "%CP%" PZTestKitLauncher "%ORIG_CWD%" %*
exit /b !errorlevel!
