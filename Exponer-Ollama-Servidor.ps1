<#
.SYNOPSIS
    Exposes local Ollama as a LAN or Tailscale/WAN access point for remote OpenCode clients (server side).
.DESCRIPTION
    Idempotent setup: verifies Ollama install, sets OLLAMA_HOST=0.0.0.0:<Port> at User
    level, ensures a Private-only inbound firewall rule for TCP <Port>, reminds about
    Ollama restart, verifies local endpoints, prints LAN IPs and a ready-to-paste
    client snippet for the other PC.
    WAN mode (different networks, no shared LAN): use -ModoTailscale. It keeps the
    LAN rule untouched, checks 'tailscale ip', and ensures a second scoped rule
    limited to 100.64.0.0/10 (Tailscale CGNAT range). It NEVER opens Public to the
    whole internet.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -Port 11434 -ModelHint "qwen2.5-coder:7b"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -ModoTailscale
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -KeepAlive "24h"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -Limpiar
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -Limpiar -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$Port = 11434,
    [string]$ModelHint = "",
    [switch]$ModoTailscale,
    # How long Ollama keeps a loaded model in memory (e.g. "5m", "24h", "0", "-1").
    [ValidatePattern('^(\d+[smh]|-1|0)$')]
    [string]$KeepAlive = "24h",
    # Cleanup mode: remove User OLLAMA_HOST (only when 0.0.0.0:<Port>, else confirm) + both firewall rules.
    [switch]$Limpiar,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Limpiar: undo what Exponer created (same names as normal mode) ---
if ($Limpiar) {
    Write-Host "Modo Limpiar: deshaciendo lo creado por Exponer..." -ForegroundColor Cyan
    $desiredHost = "0.0.0.0:{0}" -f $Port
    $currentUser = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "User")
    if ([string]::IsNullOrWhiteSpace($currentUser)) {
        Write-Host "OLLAMA_HOST (User): no existe. Nada que quitar." -ForegroundColor Green
    } elseif ($currentUser -eq $desiredHost) {
        if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_HOST", "Eliminar valor '$desiredHost'")) {
            [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $null, "User")
            $env:OLLAMA_HOST = $null
            Write-Host ("Quitado: OLLAMA_HOST (User) valia '{0}'." -f $desiredHost) -ForegroundColor Green
        }
    } else {
        Write-Host ("OLLAMA_HOST (User) vale '{0}', distinto de '{1}'." -f $currentUser, $desiredHost) -ForegroundColor Yellow
        Write-Host "Parece un valor personalizado; no se toca sin confirmar." -ForegroundColor Yellow
        $borrar = $false
        if ($Force) { $borrar = $true }
        else {
            $resp = Read-Host "Borrarlo de todos modos? [s/N]"
            if ($resp -eq "s" -or $resp -eq "S" -or $resp -eq "si" -or $resp -eq "SI") { $borrar = $true }
        }
        if ($borrar) {
            if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_HOST", "Eliminar valor personalizado '$currentUser'")) {
                [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $null, "User")
                $env:OLLAMA_HOST = $null
                Write-Host "Quitado: OLLAMA_HOST (User) personalizado." -ForegroundColor Green
            }
        } else {
            Write-Host "Queda: OLLAMA_HOST (User) personalizado intacto." -ForegroundColor Cyan
        }
    }
    # OLLAMA_KEEP_ALIVE set by Exponer/Responder: remove with confirm unless -Force.
    $currentKeep = [Environment]::GetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "User")
    if ([string]::IsNullOrWhiteSpace($currentKeep)) {
        Write-Host "OLLAMA_KEEP_ALIVE (User): no existe. Nada que quitar." -ForegroundColor Green
    } else {
        Write-Host ("OLLAMA_KEEP_ALIVE (User) vale '{0}'." -f $currentKeep) -ForegroundColor Yellow
        $borrarKeep = $false
        if ($Force) { $borrarKeep = $true }
        else {
            $respKeep = Read-Host "Borrar OLLAMA_KEEP_ALIVE tambien? [s/N]"
            if ($respKeep -eq "s" -or $respKeep -eq "S" -or $respKeep -eq "si" -or $respKeep -eq "SI") { $borrarKeep = $true }
        }
        if ($borrarKeep) {
            if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_KEEP_ALIVE", "Eliminar valor '$currentKeep'")) {
                [Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", $null, "User")
                $env:OLLAMA_KEEP_ALIVE = $null
                Write-Host "Quitado: OLLAMA_KEEP_ALIVE (User)." -ForegroundColor Green
            }
        } else {
            Write-Host "Queda: OLLAMA_KEEP_ALIVE (User) intacto." -ForegroundColor Cyan
        }
    }
    foreach ($ruleName in @(("Ollama LAN TCP {0}" -f $Port), ("Ollama Tailscale TCP {0}" -f $Port))) {
        try {
            $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            if ($null -eq $existing) {
                Write-Host ("Regla '{0}': no existe. Ya limpio." -f $ruleName) -ForegroundColor Green
            } elseif ($PSCmdlet.ShouldProcess("Regla firewall '$ruleName'", "Eliminar")) {
                try {
                    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
                    Write-Host ("Quitada: regla '{0}'." -f $ruleName) -ForegroundColor Green
                } catch {
                    Write-Host ("Aviso: no se pudo quitar '{0}' (requiere Admin): {1}" -f $ruleName, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host ("Aviso en firewall '{0}': {1} (requiere Admin para quitar)." -f $ruleName, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Write-Host "Queda (no se toca): Ollama instalado, modelos descargados." -ForegroundColor Cyan
    Write-Host "Limpieza terminada. Reinicie Ollama (Quit + ollama serve) para aplicar." -ForegroundColor Green
    exit 0
}

# --- 1. Verify Ollama is installed ---
Write-Host "Paso 1/5: Verificando instalacion de Ollama..." -ForegroundColor Cyan
$ollamaCmd = Get-Command "ollama" -ErrorAction SilentlyContinue
if ($null -eq $ollamaCmd) {
    Write-Host "ERROR: no se encontro el comando 'ollama' en el PATH." -ForegroundColor Red
    Write-Host "Instale Ollama desde https://ollama.com/download y vuelva a ejecutar este script." -ForegroundColor Yellow
    exit 1
}
try {
    $versionOut = & ollama --version 2>&1 | Out-String
    Write-Host ("Ollama detectado: {0}" -f $versionOut.Trim()) -ForegroundColor Green
} catch {
    Write-Host ("ERROR al ejecutar 'ollama --version': {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
try {
    Write-Host "Modelos locales (ollama list):" -ForegroundColor Cyan
    & ollama list 2>&1 | Out-String | Write-Host
} catch {
    Write-Host ("Aviso: no se pudo listar modelos: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- 2. Set OLLAMA_HOST at User level (idempotent) ---
Write-Host " " 
Write-Host ("Paso 2/5: Configurando OLLAMA_HOST=0.0.0.0:{0} (nivel User)..." -f $Port) -ForegroundColor Cyan
$desiredHost = "0.0.0.0:{0}" -f $Port
$currentUser = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "User")
if ($currentUser -eq $desiredHost) {
    Write-Host "Ollama_HOST ya esta configurado a nivel User. Sin cambios." -ForegroundColor Green
} else {
    if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_HOST", "Fijar a $desiredHost")) {
        [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $desiredHost, "User")
        $env:OLLAMA_HOST = $desiredHost
        Write-Host ("OLLAMA_HOST fijado a '{0}' para el usuario actual." -f $desiredHost) -ForegroundColor Green
    }
}
Write-Host "Nota: si Ollama corre como servicio de Windows, el servicio usa variables de" -ForegroundColor Yellow
Write-Host "  nivel System, no User. Para ese caso (requiere PowerShell como Admin):" -ForegroundColor Yellow
Write-Host ("  [Environment]::SetEnvironmentVariable('OLLAMA_HOST', '{0}', 'Machine')" -f $desiredHost) -ForegroundColor Yellow
Write-Host "  y luego reinicie el servicio o la PC." -ForegroundColor Yellow

# --- 2b. Set OLLAMA_KEEP_ALIVE at User level (idempotent, custom needs confirm) ---
Write-Host " "
Write-Host ("Paso 2b/5: Configurando OLLAMA_KEEP_ALIVE={0} (nivel User)..." -f $KeepAlive) -ForegroundColor Cyan
$currentKeep = [Environment]::GetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "User")
if ($currentKeep -ceq $KeepAlive) {
    Write-Host ("OLLAMA_KEEP_ALIVE ya vale '{0}'. Sin cambios." -f $KeepAlive) -ForegroundColor Green
} elseif (-not [string]::IsNullOrWhiteSpace($currentKeep)) {
    Write-Host ("OLLAMA_KEEP_ALIVE (User) vale '{0}', distinto de '{1}'." -f $currentKeep, $KeepAlive) -ForegroundColor Yellow
    Write-Host "Parece un valor personalizado; no se toca sin confirmar." -ForegroundColor Yellow
    $fijarKeep = $false
    if ($Force) { $fijarKeep = $true }
    else {
        $respKeep = Read-Host "Sobrescribirlo con '$KeepAlive'? [s/N]"
        if ($respKeep -eq "s" -or $respKeep -eq "S" -or $respKeep -eq "si" -or $respKeep -eq "SI") { $fijarKeep = $true }
    }
    if ($fijarKeep) {
        if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_KEEP_ALIVE", "Fijar a $KeepAlive")) {
            [Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", $KeepAlive, "User")
            $env:OLLAMA_KEEP_ALIVE = $KeepAlive
            Write-Host ("OLLAMA_KEEP_ALIVE fijado a '{0}'." -f $KeepAlive) -ForegroundColor Green
        }
    } else {
        Write-Host ("Queda: OLLAMA_KEEP_ALIVE (User) personalizado '{0}' intacto." -f $currentKeep) -ForegroundColor Cyan
    }
} else {
    if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_KEEP_ALIVE", "Fijar a $KeepAlive")) {
        [Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", $KeepAlive, "User")
        $env:OLLAMA_KEEP_ALIVE = $KeepAlive
        Write-Host ("OLLAMA_KEEP_ALIVE fijado a '{0}' para el usuario actual." -f $KeepAlive) -ForegroundColor Green
    }
}
Write-Host ("OLLAMA_KEEP_ALIVE actual: {0}" -f $KeepAlive) -ForegroundColor Cyan
Write-Host "Aviso: Ollama debe reiniciarse para aplicar OLLAMA_KEEP_ALIVE (Quit + ollama serve)." -ForegroundColor Yellow
if ($KeepAlive -eq "-1") {
    Write-Host "Aviso: KeepAlive '-1' mantiene el modelo siempre en VRAM: solo si sobra VRAM y usa 1 modelo." -ForegroundColor Yellow
}

# --- 3. Firewall rule: Private-only inbound TCP <Port> (idempotent, no duplicates) ---
Write-Host " " 
Write-Host ("Paso 3/5: Verificando regla de firewall (solo red Privada, TCP {0})..." -f $Port) -ForegroundColor Cyan
$ruleName = "Ollama LAN TCP {0}" -f $Port
try {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Host ("La regla '{0}' ya existe. Actualizando a perfil Private por si acaso..." -f $ruleName) -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("Regla firewall '$ruleName'", "Actualizar a perfil Private / puerto $Port")) {
            try {
                Set-NetFirewallRule -DisplayName $ruleName -Profile Private -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -ErrorAction Stop
                Write-Host "Regla actualizada correctamente." -ForegroundColor Green
            } catch {
                Write-Host ("Aviso: no se pudo actualizar la regla (¿falta Admin?): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } else {
        if ($PSCmdlet.ShouldProcess("Regla firewall '$ruleName'", "Crear regla inbound TCP $Port perfil Private")) {
            try {
                New-NetFirewallRule -DisplayName $ruleName `
                    -Description "Permite acceso LAN a Ollama (solo redes privadas). Creado por Exponer-Ollama-Servidor.ps1" `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                    -Profile Private -ErrorAction Stop | Out-Null
                Write-Host ("Regla '{0}' creada (solo perfil Private)." -f $ruleName) -ForegroundColor Green
            } catch {
                Write-Host ("Aviso: no se pudo crear la regla (ejecute como Admin): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                Write-Host "Comando manual (PowerShell Admin):" -ForegroundColor Yellow
                Write-Host ("  New-NetFirewallRule -DisplayName '{0}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {1} -Profile Private" -f $ruleName, $Port) -ForegroundColor Yellow
            }
        }
    }
} catch {
    Write-Host ("Aviso en firewall: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- 3b. Tailscale / WAN check (only with -ModoTailscale, idempotent) ---
# Rationale: server and client are on different networks (no shared LAN).
# Tailscale gives NAT-traversal without router config. This block does NOT
# install anything and NEVER opens Public to the internet; the extra rule is
# scoped to the Tailscale CGNAT range 100.64.0.0/10 only.
$tailscaleIp = ""
if ($ModoTailscale) {
    Write-Host " " 
    Write-Host "Paso 3b/6: Chequeo Tailscale (modo WAN)..." -ForegroundColor Cyan
    $tailscaleCmd = Get-Command "tailscale" -ErrorAction SilentlyContinue
    if ($null -eq $tailscaleCmd) {
        Write-Host "Aviso: 'tailscale' no esta en el PATH de este servidor." -ForegroundColor Yellow
        Write-Host "Instale Tailscale desde https://tailscale.com/download e inicie sesion en ambas PCs." -ForegroundColor Yellow
        Write-Host "Luego repita este script con -ModoTailscale. No se instala nada automaticamente." -ForegroundColor Yellow
    } else {
        try {
            $tailscaleIp = (& tailscale ip --ipv4 2>&1 | Out-String).Trim().Split("`n")[0].Trim()
            Write-Host ("IP Tailscale detectada: {0}" -f $tailscaleIp) -ForegroundColor Green
        } catch {
            Write-Host ("Aviso: 'tailscale ip' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
        try {
            Write-Host "Estado Tailscale (tailscale status):" -ForegroundColor Cyan
            & tailscale status 2>&1 | Out-String | Write-Host
        } catch {
            Write-Host ("Aviso: 'tailscale status' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
        if ([string]::IsNullOrWhiteSpace($tailscaleIp) -or $tailscaleIp -notlike "100.*") {
            Write-Host "Aviso: no se detecto una IP 100.x valida. Verifique login: 'tailscale login' y 'tailscale status'." -ForegroundColor Yellow
        }
    }
    # Scoped firewall rule for Tailscale only (RemoteAddress 100.64.0.0/10).
    # Note: Windows often classifies the Tailscale adapter as Public/Unidentified,
    # so a Private-only rule would not match. Scoping by RemoteAddress keeps it
    # safe without opening Public to the whole internet.
    $tsRuleName = "Ollama Tailscale TCP {0}" -f $Port
    $tsRange = "100.64.0.0/10"
    try {
        $existingTs = Get-NetFirewallRule -DisplayName $tsRuleName -ErrorAction SilentlyContinue
        if ($null -ne $existingTs) {
            Write-Host ("La regla '{0}' ya existe. Verificando alcance a {1}..." -f $tsRuleName, $tsRange) -ForegroundColor Green
        } else {
            if ($PSCmdlet.ShouldProcess("Regla firewall '$tsRuleName'", "Crear regla inbound TCP $Port limitada a $tsRange")) {
                try {
                    New-NetFirewallRule -DisplayName $tsRuleName `
                        -Description "Permite Ollama solo desde la red Tailscale (100.64.0.0/10). Creado por Exponer-Ollama-Servidor.ps1 -ModoTailscale. Nunca abrir a Public/internet." `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                        -RemoteAddress $tsRange -Profile Any -ErrorAction Stop | Out-Null
                    Write-Host ("Regla '{0}' creada (solo {1}, perfil Any acotado)." -f $tsRuleName, $tsRange) -ForegroundColor Green
                } catch {
                    Write-Host ("Aviso: no se pudo crear la regla Tailscale (ejecute como Admin): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    Write-Host "Comando manual (PowerShell Admin):" -ForegroundColor Yellow
                    Write-Host ("  New-NetFirewallRule -DisplayName '{0}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {1} -RemoteAddress {2} -Profile Any" -f $tsRuleName, $Port, $tsRange) -ForegroundColor Yellow
                }
            }
        }
    } catch {
        Write-Host ("Aviso en firewall Tailscale: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host "SEGURIDAD: no se abrio nada a Public/internet abierto. Solo LAN privada + rango Tailscale." -ForegroundColor Green
}

# --- 4. Reminder to restart Ollama ---
Write-Host " " 
Write-Host "Paso 4/5: Reinicio de Ollama (requerido para aplicar OLLAMA_HOST)..." -ForegroundColor Cyan
$ollamaProc = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($null -ne $ollamaProc) {
    Write-Host "Ollama esta en ejecucion. Debe reiniciarlo para que OLLAMA_HOST aplique:" -ForegroundColor Yellow
    Write-Host "  1. Cierre Ollama (icono bandeja -> Quit) o ejecute: Stop-Process -Name ollama -Force" -ForegroundColor Yellow
    Write-Host "  2. Inicie de nuevo:  ollama serve   (o abra la app de Ollama)" -ForegroundColor Yellow
    Write-Host "Esperando 8 segundos antes de verificar, reinicie Ollama ahora si puede..." -ForegroundColor Yellow
    Start-Sleep -Seconds 8
} else {
    Write-Host "No se detecto proceso Ollama en ejecucion." -ForegroundColor Green
    Write-Host "Si Ollama estaba configurado con otro HOST, inicie con:  ollama serve" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

# --- 5. Verify local endpoints ---
Write-Host " " 
Write-Host "Paso 5/5: Verificando endpoints locales..." -ForegroundColor Cyan
$tagsUrl = "http://localhost:{0}/api/tags" -f $Port
$modelsUrl = "http://localhost:{0}/v1/models" -f $Port
$tagsOk = $false
$detectedModel = $ModelHint
try {
    $tagsResp = Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
    $tagsOk = $true
    Write-Host ("OK: {0} responde." -f $tagsUrl) -ForegroundColor Green
    # Detect first model from /api/tags if no hint given
    if ([string]::IsNullOrWhiteSpace($detectedModel)) {
        if ($null -ne $tagsResp.models -and $tagsResp.models.Count -gt 0) {
            $detectedModel = $tagsResp.models[0].name
        }
    }
} catch {
    Write-Host ("FALLO: {0} no responde: {1}" -f $tagsUrl, $_.Exception.Message) -ForegroundColor Red
    Write-Host "Revise: 1) Ollama reiniciado tras fijar OLLAMA_HOST, 2) puerto correcto, 3) 'ollama list' funciona." -ForegroundColor Yellow
}
try {
    $modelsResp = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
    Write-Host ("OK: {0} responde." -f $modelsUrl) -ForegroundColor Green
    if ([string]::IsNullOrWhiteSpace($detectedModel)) {
        if ($null -ne $modelsResp.data -and $modelsResp.data.Count -gt 0) {
            $detectedModel = $modelsResp.data[0].id
        }
    }
} catch {
    Write-Host ("FALLO: {0} no responde: {1}" -f $modelsUrl, $_.Exception.Message) -ForegroundColor Red
}
if ([string]::IsNullOrWhiteSpace($detectedModel)) {
    $detectedModel = "qwen2.5-coder:7b"
    Write-Host ("No se detecto modelo local; usando sugerencia '{0}'. Ajustelo al configurar el cliente." -f $detectedModel) -ForegroundColor Yellow
} else {
    Write-Host ("Modelo detectado/sugerido: {0}" -f $detectedModel) -ForegroundColor Green
}

# --- Detect LAN IPv4 addresses (exclude loopback) ---
Write-Host " " 
Write-Host "Direcciones IP LAN detectadas (use una de estas en la otra PC):" -ForegroundColor Cyan
try {
    $lanIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*"
    } | Sort-Object -Property IPAddress
    foreach ($ip in $lanIps) {
        Write-Host ("  {0}   ({1})" -f $ip.IPAddress, $ip.InterfaceAlias) -ForegroundColor Green
    }
    $primaryIp = $lanIps | Where-Object {
        $_.IPAddress -like "192.168.*" -or $_.IPAddress -like "10.*" -or $_.IPAddress -like "172.*"
    } | Select-Object -First 1
    if ($null -eq $primaryIp) { $primaryIp = $lanIps | Select-Object -First 1 }
    if ($null -eq $primaryIp) {
        $primaryIpValue = "SU_IP_LAN"
    } else {
        $primaryIpValue = $primaryIp.IPAddress
    }
} catch {
    Write-Host ("No se pudieron enumerar IPs: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    $primaryIpValue = "SU_IP_LAN"
}

# --- Print client snippet with real IP + detected model ---
# In -ModoTailscale the snippet prefers the 100.x IP (or MagicDNS name) so the
# client works across different physical networks. LAN IPs are still shown.
$snippetHost = $primaryIpValue
$snippetName = "Ollama Remoto (LAN)"
if ($ModoTailscale) {
    $snippetName = "Ollama Remoto (Tailscale)"
    if (-not [string]::IsNullOrWhiteSpace($tailscaleIp) -and $tailscaleIp -like "100.*") {
        $snippetHost = $tailscaleIp
    }
    Write-Host " " 
    Write-Host "IP Tailscale a usar en el cliente (red WAN, sin LAN comun):" -ForegroundColor Cyan
    if ($snippetHost -like "100.*") {
        Write-Host ("  {0}  (tambien vale el hostname MagicDNS, ej. mi-pc.tailXXXX.ts.net)" -f $snippetHost) -ForegroundColor Green
    } else {
        Write-Host "  No detectada. Use 'tailscale ip --ipv4' en este servidor." -ForegroundColor Yellow
    }
}
Write-Host " " 
Write-Host "=== SNIPPET CLIENTE (copie en la otra PC) ===" -ForegroundColor Cyan
$clientJson = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama-remoto": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "$snippetName",
      "options": {
        "baseURL": "http://$snippetHost`:$Port/v1"
      },
      "models": {
        "$detectedModel": { "name": "$detectedModel (remoto)" }
      }
    }
  }
}
"@
Write-Host $clientJson
Write-Host " " 
Write-Host "Comandos de verificacion para la OTRA PC (ajúste IP si usa otra):" -ForegroundColor Cyan
Write-Host ("  curl.exe http://{0}:{1}/api/tags" -f $primaryIpValue, $Port)
Write-Host ("  curl.exe http://{0}:{1}/v1/models" -f $primaryIpValue, $Port)
if ($ModoTailscale -and $snippetHost -like "100.*") {
    Write-Host ("  curl.exe http://{0}:{1}/api/tags   # via Tailscale" -f $snippetHost, $Port)
    Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File ""Configurar-Opencode-Remoto.ps1"" -RemoteHost {0} -Port {1} -Model ""{2}"" -ModoTailscale" -f $snippetHost, $Port, $detectedModel) -ForegroundColor Green
} else {
    Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File ""Configurar-Opencode-Remoto.ps1"" -RemoteHost {0} -Port {1} -Model ""{2}""" -f $primaryIpValue, $Port, $detectedModel)
}
Write-Host " " 
Write-Host "Servidor listo. Si /api/tags fallo arriba, reinicie Ollama y repita el paso 5." -ForegroundColor Cyan
