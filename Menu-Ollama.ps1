<#
.SYNOPSIS
    Terminal menu (no dependencies) to run the Ollama LAN/Tailscale/USB scripts.
.DESCRIPTION
    Numbered menu compatible with PS 5.1 and plain console (Read-Host only,
    no arrow keys / PSReadLine / Windows Terminal assumed). Resolves sibling
    scripts relative to $PSScriptRoot, shows the exact command before running
    it, pauses after each action and loops until exit. Use -Accion for
    non-interactive mode (runs once and exits).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Diagnostico
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Solicitar -UsbPath "E:\"
#>
[CmdletBinding()]
param(
    [ValidateSet("", "Solicitar", "Responder", "Aplicar", "Limpiar", "Exponer", "Configurar", "Diagnostico")]
    [string]$Accion = "",
    [string]$UsbPath = "",
    [int]$Port = 11434,
    [string]$ModelHint = "",
    [string]$RemoteHost = "",
    [switch]$LimpiarUSB,
    [switch]$Force,
    [bool]$ModoTailscale = $true,
    [string]$KeepAlive = "24h",
    [int]$TimeoutMs = 600000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Resolve sibling scripts relative to this file ---
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$PairingScript = Join-Path $ScriptDir "Emparejar-Ollama-USB.ps1"
$ExponerScript = Join-Path $ScriptDir "Exponer-Ollama-Servidor.ps1"
$ConfigScript = Join-Path $ScriptDir "Configurar-Opencode-Remoto.ps1"

# --- Helper: pause after each action ---
function Pause-Menu {
    Read-Host "Pulse Enter para continuar" | Out-Null
}

# --- Helper: ask optional value, Enter keeps default ---
function Read-Optional {
    param([string]$Prompt, [string]$Default)
    $v = Read-Host ("{0} [Enter={1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

# --- Helper: show exact command, then run target script with named splatting ---
# Note: array splatting (@array) would bind positionally and break named
# params, so callers pass a hashtable (binds by name).
function Invoke-Shown {
    param([string]$Target, [hashtable]$Splat, [string]$Label)
    Write-Host ""
    Write-Host ("Va a correr: {0}" -f $Label) -ForegroundColor Cyan
    & $Target @Splat
}

# --- Action: Solicitar / Responder / Aplicar via pairing script ---
function Invoke-Pairing {
    param([string]$Modo)
    if (-not (Test-Path -LiteralPath $PairingScript)) {
        Write-Host ("ERROR: no se encontro '{0}'." -f $PairingScript) -ForegroundColor Red
        return
    }
    $usb = $UsbPath
    $hint = $ModelHint
    $puerto = $Port
    $keepAlive = $KeepAlive
    $timeoutMs = $TimeoutMs
    if ([string]::IsNullOrWhiteSpace($Accion)) {
        # Interactive: only ask what applies to this mode.
        $u = Read-Host "Ruta USB (Enter=auto-detectar, ej. E:\)"
        if (-not [string]::IsNullOrWhiteSpace($u)) { $usb = $u.Trim() }
        if ($Modo -eq "Solicitar") {
            $h = Read-Host "Pista de modelo (Enter=omitir, ej. qwen2.5-coder:7b)"
            if (-not [string]::IsNullOrWhiteSpace($h)) { $hint = $h.Trim() }
        }
        if ($Modo -eq "Responder") {
            $p = Read-Host ("Puerto (Enter={0})" -f $puerto)
            if (-not [string]::IsNullOrWhiteSpace($p)) { $puerto = [int]$p }
            $k = Read-Optional "KeepAlive 5m/0/-1/24h (Enter=24h)" "24h"
            if ($k -notmatch '^(\d+[smh]|-1|0)$') {
                Write-Host ("KeepAlive '{0}' invalido; se usa '24h'." -f $k) -ForegroundColor Yellow
                $k = "24h"
            }
            $keepAlive = $k
        }
        if ($Modo -eq "Aplicar") {
            $t = Read-Optional "TimeoutMs >=60000 o 0=false (Enter=600000)" "600000"
            $parsed = 600000
            if (-not [int]::TryParse($t, [ref]$parsed) -or ($parsed -ne 0 -and $parsed -lt 60000)) {
                Write-Host ("TimeoutMs '{0}' invalido; se usa 600000." -f $t) -ForegroundColor Yellow
                $parsed = 600000
            }
            $timeoutMs = $parsed
        }
    }
    $splat = @{ Modo = $Modo }
    $show = @("-Modo", $Modo)
    if (-not [string]::IsNullOrWhiteSpace($usb)) { $splat["UsbPath"] = $usb; $show += @("-UsbPath", $usb) }
    if (-not [string]::IsNullOrWhiteSpace($hint) -and ($Modo -eq "Solicitar")) { $splat["ModelHint"] = $hint; $show += @("-ModelHint", $hint) }
    if ($Modo -eq "Responder") {
        $splat["Port"] = $puerto; $show += @("-Port", "$puerto")
        $splat["KeepAlive"] = $keepAlive; $show += @("-KeepAlive", $keepAlive)
    }
    if ($Modo -eq "Aplicar") { $splat["TimeoutMs"] = $timeoutMs; $show += @("-TimeoutMs", "$timeoutMs") }
    $label = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PairingScript, ($show -join " ")
    Invoke-Shown -Target $PairingScript -Splat $splat -Label $label
}

# --- Action: Limpiar (ask where: this PC and/or USB) ---
function Invoke-Limpiar {
    if (-not (Test-Path -LiteralPath $PairingScript)) {
        Write-Host ("ERROR: no se encontro '{0}'." -f $PairingScript) -ForegroundColor Red
        return
    }
    $usb = $UsbPath
    $puerto = $Port
    $withUsb = $LimpiarUSB.IsPresent
    $force = $Force.IsPresent
    if ([string]::IsNullOrWhiteSpace($Accion)) {
        $p = Read-Host ("Puerto (Enter={0})" -f $puerto)
        if (-not [string]::IsNullOrWhiteSpace($p)) { $puerto = [int]$p }
        Write-Host "Limpiar donde?" -ForegroundColor Cyan
        Write-Host "  [1] Esta PC (OLLAMA_HOST + reglas firewall)"
        Write-Host "  [2] Solo USB (carpeta ollama-pairing)"
        Write-Host "  [3] Ambos (PC + USB)"
        $d = Read-Host "Elija [1-3] (Enter=1)"
        if ($d -eq "2") { $withUsb = $true; $pcOnly = $false }
        elseif ($d -eq "3") { $withUsb = $true; $pcOnly = $true }
        else { $pcOnly = $true }
        if ($withUsb -and [string]::IsNullOrWhiteSpace($usb)) {
            $u = Read-Host "Ruta USB (Enter=auto-detectar, ej. E:\)"
            if (-not [string]::IsNullOrWhiteSpace($u)) { $usb = $u.Trim() }
        }
        if ($pcOnly -eq $false -and $withUsb) {
            # USB only: still runs Limpiar (PC part is idempotent no-op if clean).
            Write-Host "Solo USB: igual se revisa esta PC (idempotente, sin cambios si ya esta limpia)." -ForegroundColor Yellow
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($usb)) { $withUsb = $true }
    }
    $splat = @{ Modo = "Limpiar"; Port = $puerto }
    $show = @("-Modo", "Limpiar", "-Port", "$puerto")
    if (-not [string]::IsNullOrWhiteSpace($usb)) { $splat["UsbPath"] = $usb; $show += @("-UsbPath", $usb) }
    if ($withUsb) { $splat["LimpiarUSB"] = $true; $show += @("-LimpiarUSB") }
    if ($force) { $splat["Force"] = $true; $show += @("-Force") }
    $label = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PairingScript, ($show -join " ")
    Invoke-Shown -Target $PairingScript -Splat $splat -Label $label
}

# --- Action: Exponer (direct server, no USB) ---
function Invoke-Exponer {
    if (-not (Test-Path -LiteralPath $ExponerScript)) {
        Write-Host ("ERROR: no se encontro '{0}'." -f $ExponerScript) -ForegroundColor Red
        return
    }
    $puerto = $Port
    $hint = $ModelHint
    $ts = $ModoTailscale
    $keepAlive = $KeepAlive
    if ([string]::IsNullOrWhiteSpace($Accion)) {
        $p = Read-Host ("Puerto (Enter={0})" -f $puerto)
        if (-not [string]::IsNullOrWhiteSpace($p)) { $puerto = [int]$p }
        $h = Read-Host "Pista de modelo (Enter=omitir)"
        if (-not [string]::IsNullOrWhiteSpace($h)) { $hint = $h.Trim() }
        $k = Read-Optional "KeepAlive 5m/0/-1/24h (Enter=24h)" "24h"
        if ($k -notmatch '^(\d+[smh]|-1|0)$') {
            Write-Host ("KeepAlive '{0}' invalido; se usa '24h'." -f $k) -ForegroundColor Yellow
            $k = "24h"
        }
        $keepAlive = $k
        $t = Read-Host "Incluir regla Tailscale? [s/N]"
        if ($t -eq "s" -or $t -eq "S") { $ts = $true } else { $ts = $false }
    }
    $splat = @{ Port = $puerto; KeepAlive = $keepAlive }
    $show = @("-Port", "$puerto", "-KeepAlive", $keepAlive)
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $splat["ModelHint"] = $hint; $show += @("-ModelHint", $hint) }
    if ($ts) { $splat["ModoTailscale"] = $true; $show += @("-ModoTailscale") }
    $label = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ExponerScript, ($show -join " ")
    Invoke-Shown -Target $ExponerScript -Splat $splat -Label $label
}

# --- Action: Configurar (direct client, asks IP) ---
function Invoke-Configurar {
    if (-not (Test-Path -LiteralPath $ConfigScript)) {
        Write-Host ("ERROR: no se encontro '{0}'." -f $ConfigScript) -ForegroundColor Red
        return
    }
    $hostRemoto = $RemoteHost
    $puerto = $Port
    $modelo = $ModelHint
    $ts = $ModoTailscale
    $timeoutMs = $TimeoutMs
    if ([string]::IsNullOrWhiteSpace($hostRemoto)) {
        if ([string]::IsNullOrWhiteSpace($Accion)) {
            $hostRemoto = Read-Host "IP del servidor (LAN 192.168.x.x, Tailscale 100.x o MagicDNS)"
            $hostRemoto = $hostRemoto.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($hostRemoto)) {
        Write-Host "ERROR: falta la IP del servidor (-RemoteHost)." -ForegroundColor Red
        return
    }
    if ([string]::IsNullOrWhiteSpace($Accion)) {
        $p = Read-Host ("Puerto (Enter={0})" -f $puerto)
        if (-not [string]::IsNullOrWhiteSpace($p)) { $puerto = [int]$p }
        $m = Read-Host "Modelo (Enter=auto-detectar)"
        if (-not [string]::IsNullOrWhiteSpace($m)) { $modelo = $m.Trim() }
        $tt = Read-Optional "TimeoutMs >=60000 o 0=false (Enter=600000)" "600000"
        $parsed = 600000
        if (-not [int]::TryParse($tt, [ref]$parsed) -or ($parsed -ne 0 -and $parsed -lt 60000)) {
            Write-Host ("TimeoutMs '{0}' invalido; se usa 600000." -f $tt) -ForegroundColor Yellow
            $parsed = 600000
        }
        $timeoutMs = $parsed
        $t = Read-Host "Modo Tailscale/WAN? [s/N]"
        if ($t -eq "s" -or $t -eq "S") { $ts = $true } else { $ts = $false }
    }
    $splat = @{ RemoteHost = $hostRemoto; Port = $puerto; TimeoutMs = $timeoutMs }
    $show = @("-RemoteHost", $hostRemoto, "-Port", "$puerto", "-TimeoutMs", "$timeoutMs")
    if (-not [string]::IsNullOrWhiteSpace($modelo)) { $splat["Model"] = $modelo; $show += @("-Model", $modelo) }
    if ($ts) { $splat["ModoTailscale"] = $true; $show += @("-ModoTailscale") }
    $label = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ConfigScript, ($show -join " ")
    Invoke-Shown -Target $ConfigScript -Splat $splat -Label $label
}

# --- Action: Copiar todo al USB (interactive only, no Admin needed) ---
function Invoke-CopiarUSB {
    $wanted = @(
        "Menu-Ollama.ps1",
        "Emparejar-Ollama-USB.ps1",
        "Exponer-Ollama-Servidor.ps1",
        "Configurar-Opencode-Remoto.ps1",
        "README.md",
        "Abrir-Menu-Ollama.bat"
    )
    $found = @()
    $missing = @()
    foreach ($n in $wanted) {
        $p = Join-Path $ScriptDir $n
        if (Test-Path -LiteralPath $p) { $found += $p }
        else { $missing += $n }
    }
    if ($missing.Count -gt 0) {
        Write-Host ("AVISO: faltan archivos junto al menu: {0}" -f ($missing -join ", ")) -ForegroundColor Yellow
    }
    if ($found.Count -eq 0) {
        Write-Host "ERROR: no hay nada que copiar." -ForegroundColor Red
        return
    }
    # Detect removable drives (PS 5.1 compatible, read-only, no Admin).
    $drives = @()
    try {
        $vols = Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveType -eq "Removable" -and $_.DriveLetter -and $_.OperationalStatus -eq "OK"
        }
        foreach ($v in $vols) { $drives += ("{0}:\" -f $v.DriveLetter) }
    } catch {
        $drives = @()
    }
    if ($drives.Count -eq 0) {
        try {
            $cim = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 2" -ErrorAction Stop
            foreach ($d in $cim) {
                if ($d.DeviceID) {
                    $root = $d.DeviceID.TrimEnd("\") + "\"
                    if (Test-Path -LiteralPath $root) { $drives += $root }
                }
            }
        } catch {
            $drives = @()
        }
    }
    $dest = ""
    if ($drives.Count -gt 0) {
        Write-Host "USB detectados:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $drives.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $drives[$i])
        }
        $sel = Read-Host ("Elija numero [1-{0}] o escriba letra/ruta (Enter=cancelar)" -f $drives.Count)
        if ([string]::IsNullOrWhiteSpace($sel)) { Write-Host "Cancelado." -ForegroundColor Yellow; return }
        $sel = $sel.Trim()
        $idx = 0
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $drives.Count) {
            $dest = $drives[$idx - 1]
        } else {
            $dest = $sel
        }
    } else {
        Write-Host "No se detecto ningun USB extraible." -ForegroundColor Yellow
        $m = Read-Host 'Escriba la letra/ruta del USB (ej. E:\) o Enter para cancelar'
        if ([string]::IsNullOrWhiteSpace($m)) { Write-Host "Cancelado." -ForegroundColor Yellow; return }
        $dest = $m.Trim()
    }
    if ($dest -match "^[A-Za-z]:?$") { $dest = $dest.TrimEnd("\") + "\" }
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Host ("ERROR: no existe la ruta '{0}'." -f $dest) -ForegroundColor Red
        return
    }
    Write-Host ""
    Write-Host ("Se copiaran {0} archivos a '{1}':" -f $found.Count, $dest) -ForegroundColor Cyan
    foreach ($p in $found) { Write-Host ("  - {0}" -f (Split-Path -Leaf $p)) }
    $ok = Read-Host "Continuar? [s/N]"
    if ($ok -ne "s" -and $ok -ne "S") { Write-Host "Cancelado." -ForegroundColor Yellow; return }
    $copied = 0
    foreach ($p in $found) {
        $target = Join-Path $dest (Split-Path -Leaf $p)
        Copy-Item -LiteralPath $p -Destination $target -Force
        Write-Host ("Copiado: {0}" -f (Split-Path -Leaf $p)) -ForegroundColor Green
        $copied++
    }
    Write-Host ("Listo: {0} archivos en '{1}'. En el USB, doble-click en Abrir-Menu-Ollama.bat." -f $copied, $dest) -ForegroundColor Green
}

# --- Action: Diagnostico (read-only checks) ---
function Invoke-Diagnostico {
    $puerto = $Port
    if ([string]::IsNullOrWhiteSpace($Accion)) {
        $p = Read-Host ("Puerto a probar (Enter={0})" -f $puerto)
        if (-not [string]::IsNullOrWhiteSpace($p)) { $puerto = [int]$p }
    }
    Write-Host "=== Diagnostico (solo lectura) ===" -ForegroundColor Cyan
    try {
        $v = & ollama --version 2>&1 | Out-String
        Write-Host ("ollama --version: {0}" -f $v.Trim()) -ForegroundColor Green
    } catch {
        Write-Host ("ollama --version fallo: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    try {
        Write-Host "ollama list:" -ForegroundColor Cyan
        & ollama list 2>&1 | Out-String | Write-Host
    } catch {
        Write-Host ("ollama list fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    try {
        $ts = Get-Command "tailscale" -ErrorAction SilentlyContinue
        if ($null -eq $ts) { Write-Host "tailscale: no esta en el PATH." -ForegroundColor Yellow }
        else {
            $ip = (& tailscale ip --ipv4 2>&1 | Out-String).Trim()
            Write-Host ("tailscale ip --ipv4: {0}" -f $ip) -ForegroundColor Green
            Write-Host "tailscale status:" -ForegroundColor Cyan
            & tailscale status 2>&1 | Out-String | Write-Host
        }
    } catch {
        Write-Host ("tailscale fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    $tagsUrl = "http://localhost:{0}/api/tags" -f $puerto
    try {
        Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 8 -ErrorAction Stop | Out-Null
        Write-Host ("OK: {0} responde." -f $tagsUrl) -ForegroundColor Green
    } catch {
        Write-Host ("FALLO: {0}: {1}" -f $tagsUrl, $_.Exception.Message) -ForegroundColor Red
    }
    try {
        $rules = Get-NetFirewallRule -DisplayName "Ollama*" -ErrorAction SilentlyContinue
        if ($null -eq $rules) { Write-Host "Firewall: no hay reglas 'Ollama*'." -ForegroundColor Yellow }
        else { $rules | Select-Object DisplayName, Enabled, Profile, Direction, Action | Format-Table -AutoSize | Out-String | Write-Host }
    } catch {
        Write-Host ("Firewall fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    $opPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    if (Test-Path -LiteralPath $opPath) {
        Write-Host ("opencode.json existe: {0}" -f $opPath) -ForegroundColor Green
        try {
            $rawCfg = Get-Content -LiteralPath $opPath -Raw -Encoding UTF8
            $cfg = $rawCfg | ConvertFrom-Json -ErrorAction Stop
            $prov = $null
            $pp = $cfg.provider.PSObject.Properties | Where-Object { $_.Name -eq "ollama-remoto" } | Select-Object -First 1
            if ($null -ne $pp) { $prov = $pp.Value }
            if ($null -eq $prov) {
                Write-Host "provider ollama-remoto: no configurado." -ForegroundColor Yellow
            } else {
                $to = $null
                if ($null -ne $prov.options -and ($prov.options.PSObject.Properties | Where-Object { $_.Name -eq "timeout" })) {
                    $to = $prov.options.timeout
                }
                if ($null -eq $to) { Write-Host "timeout configurado: (no definido; por defecto del SDK)." -ForegroundColor Yellow }
                elseif ($to -is [bool] -and $to -eq $false) { Write-Host "timeout configurado: false (desactivado)." -ForegroundColor Green }
                else { Write-Host ("timeout configurado: {0} ms." -f $to) -ForegroundColor Green }
            }
        } catch {
            Write-Host ("opencode.json ilegible: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    else { Write-Host ("opencode.json no existe: {0}" -f $opPath) -ForegroundColor Yellow }
    $keepUser = [Environment]::GetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "User")
    $keepProc = $env:OLLAMA_KEEP_ALIVE
    if ([string]::IsNullOrWhiteSpace($keepUser)) {
        Write-Host "OLLAMA_KEEP_ALIVE (User): (no definido)." -ForegroundColor Yellow
    } else {
        Write-Host ("OLLAMA_KEEP_ALIVE (User): {0}" -f $keepUser) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($keepProc)) {
        Write-Host ("OLLAMA_KEEP_ALIVE (proceso): {0}" -f $keepProc) -ForegroundColor Cyan
    }
}

# --- Non-interactive mode: run once and exit ---
if (-not [string]::IsNullOrWhiteSpace($Accion)) {
    switch ($Accion) {
        "Solicitar" { Invoke-Pairing -Modo "Solicitar" }
        "Responder" { Invoke-Pairing -Modo "Responder" }
        "Aplicar" { Invoke-Pairing -Modo "Aplicar" }
        "Limpiar" { Invoke-Limpiar }
        "Exponer" { Invoke-Exponer }
        "Configurar" { Invoke-Configurar }
        "Diagnostico" { Invoke-Diagnostico }
    }
    exit 0
}

# --- Interactive loop ---
while ($true) {
    Write-Host "" 
    Write-Host "=== Menu Ollama (terminal) ===" -ForegroundColor Cyan
    Write-Host "  [1] Solicitar (cliente -> USB)"
    Write-Host "  [2] Responder (servidor desde USB)"
    Write-Host "  [3] Aplicar (USB -> cliente)"
    Write-Host "  [4] Limpiar (esta PC y/o USB)"
    Write-Host "  [5] Exponer servidor directo (sin USB)"
    Write-Host "  [6] Configurar cliente directo (pide IP)"
    Write-Host "  [7] Diagnostico"
    Write-Host "  [8] Copiar todo al USB"
    Write-Host "  [0] Salir"
    $op = Read-Host "Elija numero [0-8]"
    switch ($op) {
        "1" { Invoke-Pairing -Modo "Solicitar"; Pause-Menu }
        "2" { Invoke-Pairing -Modo "Responder"; Pause-Menu }
        "3" { Invoke-Pairing -Modo "Aplicar"; Pause-Menu }
        "4" { Invoke-Limpiar; Pause-Menu }
        "5" { Invoke-Exponer; Pause-Menu }
        "6" { Invoke-Configurar; Pause-Menu }
        "7" { Invoke-Diagnostico; Pause-Menu }
        "8" { Invoke-CopiarUSB; Pause-Menu }
        "0" { Write-Host "Saliendo." -ForegroundColor Cyan; exit 0 }
        default { Write-Host "Opcion invalida: use un numero de 0 a 8." -ForegroundColor Yellow }
    }
}
