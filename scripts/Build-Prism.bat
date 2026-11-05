@echo off
setlocal
REM ---------------------------------------------------------------------------
REM  Builds a 32-bit prism.dll (https://github.com/ethindp/prism) for the mod.
REM
REM  The game is 32-bit and Prism only publishes 64-bit Windows binaries, so
REM  it is built here from the tagged source. Output: native\prism\prism.dll,
REM  which Build-Jeode.bat copies into the mod folder.
REM
REM  Needs: git, CMake 3.24+, Ninja, Visual Studio 2022 Build Tools (C++).
REM ---------------------------------------------------------------------------

set PRISM_TAG=v0.18.3
set ROOT=%~dp0..
set SRC=%ROOT%\build\prism-src
set OUT=%ROOT%\native\prism

REM  Use an x86 developer environment if one is already set up (CI does this
REM  with ilammy/msvc-dev-cmd); otherwise find Visual Studio with vswhere.
if /i "%VSCMD_ARG_TGT_ARCH%"=="x86" goto :have_msvc
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR (
    echo ERROR: Visual Studio with C++ tools not found. Install VS 2022 Build Tools with "Desktop development with C++".
    exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul 2>&1
if errorlevel 1 ( echo ERROR: vcvarsall.bat x86 failed & exit /b 1 )
:have_msvc

if not exist "%SRC%\CMakeLists.txt" (
    echo === Fetching Prism %PRISM_TAG% ===
    git clone --depth 1 --branch %PRISM_TAG% https://github.com/ethindp/prism "%SRC%"
    if errorlevel 1 ( echo ERROR: git clone failed & exit /b 1 )
)

echo === Configuring (x86, Release, shared) ===
cmake -S "%SRC%" -B "%SRC%\build-x86" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
if errorlevel 1 ( echo ERROR: configure failed & exit /b 1 )

echo === Building ===
cmake --build "%SRC%\build-x86"
if errorlevel 1 ( echo ERROR: build failed & exit /b 1 )

if not exist "%OUT%" mkdir "%OUT%"
for /r "%SRC%\build-x86" %%F in (prism.dll) do if exist "%%F" copy /Y "%%F" "%OUT%\prism.dll" >nul
if not exist "%OUT%\prism.dll" ( echo ERROR: prism.dll not found in build output & exit /b 1 )
copy /Y "%SRC%\LICENSE" "%OUT%\PRISM-LICENSE.txt" >nul

echo.
echo === DONE: %OUT%\prism.dll ===
endlocal
