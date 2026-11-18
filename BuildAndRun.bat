@echo off
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set "DCC=C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc32.exe"
if not exist "%DCC%" set "DCC=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc32.exe"
if not exist "%DCC%" goto :nodcc

echo Compiling EpubDemo.dpr with Delphi 12.2 ...
"%DCC%" -B -Q -N"%ROOT%Demo" -E"%ROOT%Demo" -U"%ROOT%" -I"%ROOT%" "%ROOT%Demo\EpubDemo.dpr"
if errorlevel 1 goto :failed

echo.
echo Running sample ...
"%ROOT%Demo\EpubDemo.exe"
if errorlevel 1 goto :failed

echo.
echo Build and test finished successfully.
exit /b 0

:nodcc
echo ERROR: Delphi compiler not found.
exit /b 2

:failed
echo ERROR: build or test failed.
exit /b 1
