<#
.SYNOPSIS
    Configures OpenCode on the client PC to use a remote Ollama server (LAN or Tailscale/WAN).
.DESCRIPTION
    Tests http://<RemoteHost>:<Port>/api/tags and /v1/models, auto-detects the
    model when -Model is omitted, backs up opencode.json with a timestamp, then
    inserts/updates the "ollama-remoto" provider without destroying the rest of
    the file. Creates a minimal valid file when none exists.
    -RemoteHost accepts a LAN IP (192.168.x.x), a Tailscale IP (100.x.y.z) or a
    MagicDNS hostname (mi-pc.tailXXXX.ts.net). Use -ModoTailscale when server
    and client are on different physical networks (no shared LAN) to get
    Tailscale-specific checks and hints. SSH tunnel remains as fallback with
    -RemoteHost localhost.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 192.168.1.50
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 192.168.1.50 -Port 11434 -Model "qwen2.5-coder:7b"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34 -Model "qwen2.5-coder:7b" -ModoTailscale
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost mi-pc.tailXXXX.ts.net -ModoTailscale
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34 -TimeoutMs 600000
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$RemoteHost,
    [int]$Port = 11434,
    [string]$Model = "",
    [string]$OpencodeJsonPath = "",
    [switch]$ModoTailscale,
    # Provider options.timeout in ms (>=60000). 0 means timeout=false (disable) with confirmation.
    [int]$TimeoutMs = 600000,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Resolve opencode.json path (global default, project fallback) ---
if ([string]::IsNullOrWhiteSpace($OpencodeJsonPath)) {
    $OpencodeJsonPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
}
Write-Host ("Archivo objetivo: {0}" -f $OpencodeJsonPath) -ForegroundColor Cyan

# --- Pre-checks for WAN/Tailscale mode (no behavior change for LAN) ---
$providerLabel = "Ollama Remoto (LAN)"
if ($ModoTailscale) {
    $providerLabel = "Ollama Remoto (Tailscale)"
    Write-Host "Modo Tailscale/WAN activo: el servidor esta en otra red (sin LAN comun)." -ForegroundColor Cyan
    $looksLan = ($RemoteHost -like "192.168.*" -or $RemoteHost -like "10.*" -or $RemoteHost -like "172.16.*" -or $RemoteHost -like "172.17.*" -or $RemoteHost -like "172.3*")
    if ($looksLan) {
        Write-Host ("Aviso: -RemoteHost '{0}' parece IP LAN, pero pidio -ModoTailscale." -f $RemoteHost) -ForegroundColor Yellow
        Write-Host "En WAN use la IP 100.x (tailscale ip) o el hostname MagicDNS (*.ts.net) del servidor." -ForegroundColor Yellow
    }
    $tsClient = Get-Command "tailscale" -ErrorAction SilentlyContinue
    if ($null -eq $tsClient) {
        Write-Host "Aviso: 'tailscale' no esta en el PATH de este cliente." -ForegroundColor Yellow
        Write-Host "Instale Tailscale desde https://tailscale.com/download y haga 'tailscale login' con la misma cuenta." -ForegroundColor Yellow
    } else {
        try {
            Write-Host "Estado Tailscale local:" -ForegroundColor Cyan
            & tailscale status 2>&1 | Out-String | Write-Host
        } catch {
            Write-Host ("Aviso: 'tailscale status' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

$tagsUrl = "http://{0}:{1}/api/tags" -f $RemoteHost, $Port
$modelsUrl = "http://{0}:{1}/v1/models" -f $RemoteHost, $Port

# --- Test connectivity with clear failure hints ---
Write-Host ("Probando {0} ..." -f $tagsUrl) -ForegroundColor Cyan
$availableModels = @()
try {
    $tagsResp = Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
    Write-Host "OK: /api/tags responde." -ForegroundColor Green
    if ($null -ne $tagsResp.models) {
        foreach ($m in $tagsResp.models) {
            if ($null -ne $m.name) { $availableModels += $m.name }
        }
    }
} catch {
    Write-Host ("FALLO: no se pudo contactar {0}" -f $tagsUrl) -ForegroundColor Red
    Write-Host ("Detalle: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    if ($ModoTailscale) {
        Write-Host "Revise en orden (modo Tailscale/WAN):" -ForegroundColor Yellow
        Write-Host "  1. Tailscale UP en ambas PCs: 'tailscale status' debe mostrar ambos nodos." -ForegroundColor Yellow
        Write-Host "  2. Misma cuenta/red Tailscale (misma tailnet); pruebe 'tailscale ping <host>'." -ForegroundColor Yellow
        Write-Host "  3. Servidor: OLLAMA_HOST=0.0.0.0:$Port y Ollama reiniciado (ollama serve)." -ForegroundColor Yellow
        Write-Host ("  4. Firewall servidor: regla 'Ollama Tailscale TCP {0}' limitada a 100.64.0.0/10 (no Public abierto)." -f $Port) -ForegroundColor Yellow
        Write-Host "  5. ACL Tailscale: permita el trafico entre sus dispositivos (admin console)." -ForegroundColor Yellow
        Write-Host "  6. Fallback SSH: ssh -L 11434:localhost:11434 usuario@servidor y use -RemoteHost localhost." -ForegroundColor Yellow
    } else {
        Write-Host "Revise en orden:" -ForegroundColor Yellow
        Write-Host "  1. Misma red: haga ping a $RemoteHost y confirme la IP del servidor (alla: Get-NetIPAddress)." -ForegroundColor Yellow
        Write-Host "  2. Servidor: OLLAMA_HOST=0.0.0.0:$Port y Ollama reiniciado (ollama serve)." -ForegroundColor Yellow
        Write-Host "  3. Firewall del servidor: regla inbound TCP $Port en perfil Private (no Public)." -ForegroundColor Yellow
        Write-Host "  4. WiFi invitado/aislamiento AP: cambie a la red privada principal del router." -ForegroundColor Yellow
        Write-Host "  5. Si estan en redes distintas (sin LAN comun): use -ModoTailscale con IP 100.x o MagicDNS," -ForegroundColor Yellow
        Write-Host "     o tunel SSH: ssh -L 11434:localhost:11434 usuario@servidor y apunte a localhost." -ForegroundColor Yellow
    }
    exit 1
}
try {
    Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop | Out-Null
    Write-Host "OK: /v1/models responde." -ForegroundColor Green
} catch {
    Write-Host ("Aviso: /v1/models fallo ({0}); continuo con /api/tags." -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- Auto-detect model when -Model omitted ---
$chosenModel = $Model.Trim()
if ([string]::IsNullOrWhiteSpace($chosenModel)) {
    if ($availableModels.Count -eq 0) {
        Write-Host "El servidor no reporto modelos. Instale uno alla: ollama pull qwen2.5-coder:7b" -ForegroundColor Yellow
        $chosenModel = Read-Host "Escriba el nombre del modelo a usar (ej. qwen2.5-coder:7b)"
    } elseif ($availableModels.Count -eq 1) {
        $chosenModel = $availableModels[0]
        Write-Host ("Modelo auto-detectado: {0}" -f $chosenModel) -ForegroundColor Green
    } else {
        Write-Host "Modelos disponibles en el servidor:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $availableModels.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f $i, $availableModels[$i])
        }
        $sel = Read-Host ("Elija numero [0-{0}] o escriba el nombre" -f ($availableModels.Count - 1))
        $idx = 0
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $availableModels.Count) {
            $chosenModel = $availableModels[$idx]
        } else {
            $chosenModel = $sel.Trim()
        }
    }
}
if ([string]::IsNullOrWhiteSpace($chosenModel)) {
    Write-Host "ERROR: no se indico ningun modelo." -ForegroundColor Red
    exit 1
}
Write-Host ("Modelo elegido: {0}" -f $chosenModel) -ForegroundColor Green

$baseUrl = "http://{0}:{1}/v1" -f $RemoteHost, $Port

# --- Backup existing file with timestamp ---
if (Test-Path -LiteralPath $OpencodeJsonPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "{0}.bak-{1}" -f $OpencodeJsonPath, $stamp
    if ($PSCmdlet.ShouldProcess($OpencodeJsonPath, "Crear backup en $backupPath")) {
        Copy-Item -LiteralPath $OpencodeJsonPath -Destination $backupPath -Force
        Write-Host ("Backup creado: {0}" -f $backupPath) -ForegroundColor Green
    }
}

# --- Load or create config (preserve existing content) ---
$config = $null
if (Test-Path -LiteralPath $OpencodeJsonPath) {
    try {
        $raw = Get-Content -LiteralPath $OpencodeJsonPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $config = New-Object PSObject
        } else {
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
        }
    } catch {
        Write-Host ("ERROR: el archivo existe pero no es JSON valido: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Restaure desde el .bak o corrija el JSON antes de reintentar." -ForegroundColor Yellow
        exit 1
    }
} else {
    $config = New-Object PSObject
    Add-Member -InputObject $config -MemberType NoteProperty -Name '$schema' -Value "https://opencode.ai/config.json"
    Write-Host "El archivo no existe; se creara uno minimo valido." -ForegroundColor Yellow
}

# Ensure "provider" node exists
if ($null -eq $config.provider) {
    Add-Member -InputObject $config -MemberType NoteProperty -Name "provider" -Value (New-Object PSObject)
}

# Build / update the ollama-remoto provider node (preserve apiKey/headers/models)
$timeoutValue = $TimeoutMs
$timeoutDisabled = $false
if ($timeoutValue -ne 0 -and $timeoutValue -lt 60000) {
    Write-Host ("ERROR: -TimeoutMs '{0}' invalido: use un entero >=60000 o 0 para desactivar." -f $timeoutValue) -ForegroundColor Red
    exit 1
}
if ($timeoutValue -eq 0) {
    $confirmOff = $false
    if ($Force) { $confirmOff = $true }
    else {
        $respOff = Read-Host "Desactivar el timeout del provider (timeout=false)? [s/N]"
        if ($respOff -eq "s" -or $respOff -eq "S" -or $respOff -eq "si" -or $respOff -eq "SI") { $confirmOff = $true }
    }
    if ($confirmOff) {
        $timeoutDisabled = $true
        Write-Host "Timeout desactivado (timeout=false) por confirmacion." -ForegroundColor Yellow
    } else {
        $timeoutValue = 600000
        Write-Host "No se desactiva; se usara el timeout por defecto 600000 ms." -ForegroundColor Cyan
    }
}
$existingProvider = $null
if ($null -ne $config.provider) {
    $pp = $config.provider.PSObject.Properties | Where-Object { $_.Name -eq "ollama-remoto" } | Select-Object -First 1
    if ($null -ne $pp) { $existingProvider = $pp.Value }
}
$providerNode = New-Object PSObject
Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "npm" -Value "@ai-sdk/openai-compatible"
Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "name" -Value $providerLabel
$optionsNode = New-Object PSObject
Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "baseURL" -Value $baseUrl
if ($null -ne $existingProvider -and $null -ne $existingProvider.options) {
    foreach ($op in @($existingProvider.options.PSObject.Properties)) {
        if ($op.Name -eq "baseURL" -or $op.Name -eq "timeout") { continue }
        Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name $op.Name -Value $op.Value
    }
}
if ($timeoutDisabled) {
    Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "timeout" -Value $false
} else {
    Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "timeout" -Value $timeoutValue
}
Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "options" -Value $optionsNode
$modelsNode = New-Object PSObject
if ($null -ne $existingProvider -and $null -ne $existingProvider.models) {
    foreach ($mp in @($existingProvider.models.PSObject.Properties)) {
        Add-Member -InputObject $modelsNode -MemberType NoteProperty -Name $mp.Name -Value $mp.Value
    }
}
Add-Member -InputObject $modelsNode -MemberType NoteProperty -Name $chosenModel -Value (@{ name = "$chosenModel (remoto)" }) -Force
Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "models" -Value $modelsNode

if ($PSCmdlet.ShouldProcess($OpencodeJsonPath, "Insertar/actualizar provider 'ollama-remoto'")) {
    # Add-Member -Force updates when it already exists, preserving sibling providers.
    Add-Member -InputObject $config.provider -MemberType NoteProperty -Name "ollama-remoto" -Value $providerNode -Force

    # Ensure parent directory exists before writing
    $parentDir = Split-Path -Parent $OpencodeJsonPath
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OpencodeJsonPath -Encoding UTF8
    Write-Host "opencode.json actualizado sin tocar el resto del archivo." -ForegroundColor Green
}
if ($timeoutDisabled) {
    Write-Host "Timeout aplicado: false (desactivado)." -ForegroundColor Green
} else {
    Write-Host ("Timeout aplicado: {0} ms." -f $timeoutValue) -ForegroundColor Green
}

# --- Print copy-paste block + next step ---
Write-Host " " 
Write-Host "=== BLOQUE PARA COPIAR-PEGAR (ya aplicado) ===" -ForegroundColor Cyan
$snippet = $config.provider.'ollama-remoto' | ConvertTo-Json -Depth 10
Write-Host '"ollama-remoto":'
Write-Host $snippet
Write-Host " " 
Write-Host "Verifique el modelo remoto con:" -ForegroundColor Cyan
Write-Host "  opencode models"
Write-Host ("Modelo configurado: ollama-remoto/{0}  ->  {1}" -f $chosenModel, $baseUrl) -ForegroundColor Green
