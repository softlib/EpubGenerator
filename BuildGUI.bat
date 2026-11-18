@echo off
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set "GUI=%ROOT%GUI"
set "DCC=C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc32.exe"
if not exist "%DCC%" set "DCC=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc32.exe"
if not exist "%DCC%" goto :nodcc

echo Compiling EpubBuilderGUI (Delphi 12.2 VCL) ...
"%DCC%" -B -Q -N"%GUI%" -E"%GUI%" -U"%ROOT%" -I"%ROOT%" -U"%GUI%" -I"%GUI%" "%GUI%\EpubBuilderGUI.dpr"
if errorlevel 1 goto :failed

echo.
echo Running self-test ...
"%GUI%\EpubBuilderGUI.exe" --selftest
if errorlevel 1 goto :failed

echo.
echo Reading self-test result ...
type "%GUI%\selftest.log" | findstr /C:"SELFTEST RESULT" /C:"OUTPUT:"
echo.
echo Build and self-test finished. Run GUI\EpubBuilderGUI.exe to start the application.
exit /b 0

:nodcc
echo ERROR: Delphi compiler not found.
exit /b 2

:failed
echo ERROR: build or self-test failed.
exit /b 1
