@echo off
REM Launcher for Menu-Ollama.ps1 (double-click, no typing needed).
REM Resolves its own folder so it works with any USB drive letter.
REM Does NOT require Admin (elevation is requested inside PS only when needed).
title Menu Ollama - USB
setlocal

REM Base folder = folder containing this .bat (handles spaces, variable drive letter).
set "BASE=%~dp0"
set "MENU=%BASE%Menu-Ollama.ps1"

REM Fallback: USB with "script-modelos-locales" subfolder structure.
if not exist "%MENU%" set "MENU=%BASE%script-modelos-locales\Menu-Ollama.ps1"

if not exist "%MENU%" (
    echo No se encontro Menu-Ollama.ps1.
    echo Buscado en:
    echo   "%BASE%Menu-Ollama.ps1"
    echo   "%BASE%script-modelos-locales\Menu-Ollama.ps1"
    echo Copie este .bat junto a los .ps1 o use la opcion 8 del menu para copiar todo al USB.
    pause
    exit /b 1
)

echo Abriendo el menu de Ollama...
echo Si Windows muestra SmartScreen, elija "Mas informacion" y "Ejecutar de todos modos".
powershell -NoProfile -ExecutionPolicy Bypass -File "%MENU%" %*

REM Keep window open on error so the message can be read.
if errorlevel 1 (
    echo.
    echo El menu termino con errores (codigo %ERRORLEVEL%).
    pause
)
endlocal
