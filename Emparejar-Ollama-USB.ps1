<#
.SYNOPSIS
    USB sneakernet pairing between an OpenCode client PC and a remote Ollama server PC.
.DESCRIPTION
    Single-file orchestrator with four modes (no autorun, explicit commands only):      Solicitar : (client PC) creates ollama-pairing/solicitud.json on the USB stick.
      Responder : (server PC) reads the request, applies the Exponer setup
                  (OLLAMA_HOST, Private firewall rule + Tailscale-scoped rule,
                  endpoint checks, model pick) and writes ollama-pairing/respuesta.json.
      Aplicar   : (client PC) finds respuesta.json on ANY removable drive (drive
                  letter may change between PCs), validates it, tests the server,
                   backs up opencode.json and inserts/updates the provider.
    Limpiar     : undoes what Responder created (User OLLAMA_HOST only when it
                   matches 0.0.0.0:<Port>, both firewall rules by exact name,
                   optional USB ollama-pairing folder with -LimpiarUSB).
    Existing scripts are NOT modified; firewall rule names match
    Exponer-Ollama-Servidor.ps1 so re-runs never duplicate rules.
    Ollama has no auth: no secrets are ever written to the USB. A future
    optional apiKey field is left empty with a warning.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Solicitar
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Solicitar -UsbPath "E:\" -ModelHint "qwen2.5-coder:7b"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Responder
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Responder -KeepAlive "24h"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar -TimeoutMs 600000
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar -ModoTailscale:$false
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar -LimpiarUSB -UsbPath "E:\"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("Solicitar", "Responder", "Aplicar", "Limpiar")]
    [string]$Modo = "Solicitar",
    [string]$UsbPath = "",
    [string]$ModelHint = "",
    [int]$Port = 11434,
    # Bool instead of switch so WAN default ($true) can be opted out with -ModoTailscale:$false on PS 5.1.
    [bool]$ModoTailscale = $true,
    [string]$OpencodeJsonPath = "",
    # Server side (-Modo Responder): how long Ollama keeps a loaded model in memory.
    [ValidatePattern('^(\d+[smh]|-1|0)$')]
    [string]$KeepAlive = "24h",
    # Client side (-Modo Solicitar hints it, -Modo Aplicar applies it): provider options.timeout in ms.
    # >=60000 normally; 0 means timeout=false (disable) with confirmation.
    [int]$TimeoutMs = 600000,
    # Only used by -Modo Limpiar: also delete ollama-pairing folder from the USB.
    [switch]$LimpiarUSB,
    # Only used by -Modo Limpiar: remove a custom OLLAMA_HOST value without asking.
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Bundle constants: versioned schema, marker folder on the USB stick.
$PairingDirName = "ollama-pairing"
$SolicitudFile = "solicitud.json"
$RespuestaFile = "respuesta.json"
$BundleVersion = 1

# --- Helper: safe property read (StrictMode-proof for JSON objects) ---
function Get-PropValue {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $p) { return $null }
    return $p.Value
}

# --- Helper: list removable drive roots (Get-Volume first, WMI fallback) ---
function Get-RemovableRoots {
    $roots = @()
    try {
        $vols = Get-Volume -DriveType Removable -ErrorAction Stop | Where-Object { $_.DriveLetter }
        foreach ($v in $vols) { $roots += ("{0}:\" -f $v.DriveLetter) }
    } catch {
        # Storage module unavailable; fall through to WMI below.
    }
    if ($roots.Count -eq 0) {
        try {
            $disks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType = 2" -ErrorAction Stop
            foreach ($d in $disks) { $roots += ($d.DeviceID + "\") }
        } catch {
            # No removable enumeration available on this machine.
        }
    }
    return @($roots | Sort-Object -Unique)
}

# --- Helper: resolve the pairing folder on the USB stick ---
function Resolve-PairingDir {
    param([string]$ExplicitUsb, [bool]$Create, [string]$MarkerFile)
    $pairingDir = ""
    if (-not [string]::IsNullOrWhiteSpace($ExplicitUsb)) {
        if (-not (Test-Path -LiteralPath $ExplicitUsb)) {
            Write-Host ("ERROR: no existe la ruta USB '{0}'. Revise la letra de unidad (Get-PSDrive)." -f $ExplicitUsb) -ForegroundColor Red
            return ""
        }
        $pairingDir = Join-Path $ExplicitUsb $PairingDirName
    } else {
        $roots = @(Get-RemovableRoots)
        if ($roots.Count -eq 0) {
            Write-Host "ERROR: no se detecto ningun USB extraible." -ForegroundColor Red
            Write-Host "Conecte el USB o pase la ruta explicita: -UsbPath 'E:\'" -ForegroundColor Yellow
            return ""
        }
        if (-not [string]::IsNullOrWhiteSpace($MarkerFile)) {
            # Letter may change between PCs: search every removable for the marker.
            $hits = @()
            foreach ($r in $roots) {
                $cand = Join-Path (Join-Path $r $PairingDirName) $MarkerFile
                if (Test-Path -LiteralPath $cand) { $hits += (Join-Path $r $PairingDirName) }
            }
            if ($hits.Count -eq 1) { return $hits[0] }
            if ($hits.Count -gt 1) {
                Write-Host "ERROR: el bundle aparece en varios USB. Indique uno con -UsbPath:" -ForegroundColor Red
                foreach ($h in $hits) { Write-Host ("  -UsbPath '{0}'" -f $h) -ForegroundColor Yellow }
                return ""
            }
            # No marker found: only acceptable when creating a fresh request.
            if (-not $Create) {
                Write-Host ("ERROR: no se encontro '{0}/{1}' en ningun USB." -f $PairingDirName, $MarkerFile) -ForegroundColor Red
                Write-Host "Unidades extraibles revisadas:" -ForegroundColor Yellow
                foreach ($r in $roots) { Write-Host ("  {0}" -f $r) -ForegroundColor Yellow }
                return ""
            }
        }
        if ([string]::IsNullOrWhiteSpace($pairingDir)) {
            if ($roots.Count -gt 1 -and $Create) {
                Write-Host "ERROR: hay varios USB conectados. Indique uno con -UsbPath:" -ForegroundColor Red
                foreach ($r in $roots) { Write-Host ("  -UsbPath '{0}'" -f $r) -ForegroundColor Yellow }
                return ""
            }
            $pairingDir = Join-Path $roots[0] $PairingDirName
        }
    }
    if ($Create -and -not (Test-Path -LiteralPath $pairingDir)) {
        New-Item -ItemType Directory -Path $pairingDir -Force | Out-Null
        Write-Host ("Carpeta creada: {0}" -f $pairingDir) -ForegroundColor Green
    }
    return $pairingDir
}

# --- Helper: validate solicitud.json schema ---
function Test-SolicitudSchema {
    param([object]$Obj)
    if ($null -eq $Obj) { return "bundle vacio o ilegible" }
    $ver = Get-PropValue $Obj "version"
    if ($ver -ne $BundleVersion) { return ("version no soportada ('{0}'); se esperaba version {1}. Regenere la solicitud con este script." -f $ver, $BundleVersion) }
    foreach ($f in @("clientId", "fecha")) {
        $v = Get-PropValue $Obj $f
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return ("campo requerido faltante o vacio: '{0}'. Bundle corrupto: regenere la solicitud." -f $f) }
    }
    return ""
}

# --- Helper: validate respuesta.json schema ---
function Test-RespuestaSchema {
    param([object]$Obj)
    if ($null -eq $Obj) { return "bundle vacio o ilegible" }
    $ver = Get-PropValue $Obj "version"
    if ($ver -ne $BundleVersion) { return ("version no soportada ('{0}'); se esperaba version {1}. Regenere la respuesta en el servidor con este script." -f $ver, $BundleVersion) }
    foreach ($f in @("serverId", "fecha", "tailscaleIp100x", "puerto", "modeloElegido", "baseURL", "providerName")) {
        $v = Get-PropValue $Obj $f
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return ("campo requerido faltante o vacio: '{0}'. Bundle corrupto: regenere la respuesta en el servidor." -f $f) }
    }
    return ""
}

# --- Helper: pick best model honoring an optional hint ---
function Select-BestModel {
    param([string[]]$Available, [string]$Hint)
    if ($Available.Count -eq 0) { return "" }
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        foreach ($m in $Available) {
            if ($m -eq $Hint) { return $m }
        }
        foreach ($m in $Available) {
            if ($m -like ("*{0}*" -f $Hint)) { return $m }
        }
        Write-Host ("Aviso: el modelHint '{0}' no esta en el servidor; se auto-elegira otro." -f $Hint) -ForegroundColor Yellow
    }
    foreach ($m in $Available) {
        if ($m -match "(?i)coder|code|qwen|deepseek|starcoder") { return $m }
    }
    return $Available[0]
}

# ============================================================
# MODO 1: Solicitar (PC cliente) — write solicitud.json to USB
# ============================================================
if ($Modo -eq "Solicitar") {
    Write-Host "Modo Solicitar: generando solicitud en el USB (PC cliente)..." -ForegroundColor Cyan
    $pairingDir = Resolve-PairingDir -ExplicitUsb $UsbPath -Create $true -MarkerFile ""
    if ([string]::IsNullOrWhiteSpace($pairingDir)) { exit 1 }
    $outFile = Join-Path $pairingDir $SolicitudFile
    if ([string]::IsNullOrWhiteSpace($OpencodeJsonPath)) {
        $OpencodeJsonPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    }
    $solicitud = [PSCustomObject]@{
        version           = $BundleVersion
        clientId          = ("{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format "yyyyMMdd-HHmmss"))
        fecha             = (Get-Date -Format "o")
        modelHint         = $ModelHint
        tailscaleUserHint = ""
        opencodePathHint  = $OpencodeJsonPath
        puertoSugerido    = $Port
        timeoutHint       = $TimeoutMs
    }
    if (Test-Path -LiteralPath $outFile) {
        Write-Host ("Ya existe {0}; se sobrescribira (idempotente)." -f $outFile) -ForegroundColor Yellow
    }
    if ($PSCmdlet.ShouldProcess($outFile, "Escribir solicitud de emparejamiento")) {
        $solicitud | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outFile -Encoding UTF8
        Write-Host ("Solicitud escrita: {0}" -f $outFile) -ForegroundColor Green
    }
    Write-Host "Lleve este USB al servidor (PC con el modelo local) y alla ejecute:" -ForegroundColor Cyan
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Responder' -ForegroundColor Green
    exit 0
}

# ============================================================
# MODO 2: Responder (PC servidor) — setup + write respuesta.json
# ============================================================
if ($Modo -eq "Responder") {
    Write-Host "Modo Responder: leyendo solicitud y configurando servidor (PC con Ollama)..." -ForegroundColor Cyan
    $pairingDir = Resolve-PairingDir -ExplicitUsb $UsbPath -Create $true -MarkerFile ""
    if ([string]::IsNullOrWhiteSpace($pairingDir)) { exit 1 }
    $inFile = Join-Path $pairingDir $SolicitudFile
    $outFile = Join-Path $pairingDir $RespuestaFile
    $hintModel = $ModelHint
    if (Test-Path -LiteralPath $inFile) {
        try {
            $rawIn = Get-Content -LiteralPath $inFile -Raw -Encoding UTF8
            $sol = $rawIn | ConvertFrom-Json -ErrorAction Stop
            $errIn = Test-SolicitudSchema $sol
            if (-not [string]::IsNullOrWhiteSpace($errIn)) {
                Write-Host ("ERROR: solicitud invalida: {0}" -f $errIn) -ForegroundColor Red
                exit 1
            }
            $fileHint = [string](Get-PropValue $sol "modelHint")
            if ([string]::IsNullOrWhiteSpace($hintModel) -and -not [string]::IsNullOrWhiteSpace($fileHint)) { $hintModel = $fileHint }
            $pSug = Get-PropValue $sol "puertoSugerido"
            if ($Port -eq 11434 -and $null -ne $pSug -and ([int]$pSug -gt 0)) { $Port = [int]$pSug }
            $timeoutHint = Get-PropValue $sol "timeoutHint"
            if ($null -ne $timeoutHint) {
                Write-Host "Aviso: timeoutHint del cliente se ignora; solo aplica keepAlive del servidor." -ForegroundColor Yellow
            }
            Write-Host ("Solicitud valida del cliente '{0}'." -f (Get-PropValue $sol "clientId")) -ForegroundColor Green
        } catch {
            Write-Host ("ERROR: no se pudo leer la solicitud: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Si el archivo esta corrupto, regenere con -Modo Solicitar en el cliente." -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Host "Aviso: no hay solicitud.json en el USB; se continua con valores por defecto." -ForegroundColor Yellow
    }

    # --- 1. Verify Ollama install ---
    Write-Host "Paso 1/5: Verificando instalacion de Ollama..." -ForegroundColor Cyan
    $ollamaCmd = Get-Command "ollama" -ErrorAction SilentlyContinue
    if ($null -eq $ollamaCmd) {
        Write-Host "ERROR: no se encontro el comando 'ollama' en el PATH." -ForegroundColor Red
        Write-Host "Instale Ollama desde https://ollama.com/download y repita -Modo Responder." -ForegroundColor Yellow
        exit 1
    }
    try {
        $versionOut = & ollama --version 2>&1 | Out-String
        Write-Host ("Ollama detectado: {0}" -f $versionOut.Trim()) -ForegroundColor Green
    } catch {
        Write-Host ("ERROR al ejecutar 'ollama --version': {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }

    # --- 2. Set OLLAMA_HOST at User level (idempotent) ---
    Write-Host ("Paso 2/5: Configurando OLLAMA_HOST=0.0.0.0:{0} (nivel User)..." -f $Port) -ForegroundColor Cyan
    $desiredHost = "0.0.0.0:{0}" -f $Port
    $currentUser = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "User")
    if ($currentUser -eq $desiredHost) {
        Write-Host "OLLAMA_HOST ya esta configurado a nivel User. Sin cambios." -ForegroundColor Green
    } elseif ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_HOST", "Fijar a $desiredHost")) {
        [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $desiredHost, "User")
        $env:OLLAMA_HOST = $desiredHost
        Write-Host ("OLLAMA_HOST fijado a '{0}'." -f $desiredHost) -ForegroundColor Green
    }

    # --- 2b. Set OLLAMA_KEEP_ALIVE at User level (idempotent, custom needs confirm) ---
    Write-Host ("Paso 2b/5: Configurando OLLAMA_KEEP_ALIVE={0} (nivel User)..." -f $KeepAlive) -ForegroundColor Cyan
    $currentKeep = [Environment]::GetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "User")
    $effectiveKeep = $KeepAlive
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
            $effectiveKeep = $currentKeep
        }
    } else {
        if ($PSCmdlet.ShouldProcess("Variable de usuario OLLAMA_KEEP_ALIVE", "Fijar a $KeepAlive")) {
            [Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", $KeepAlive, "User")
            $env:OLLAMA_KEEP_ALIVE = $KeepAlive
            Write-Host ("OLLAMA_KEEP_ALIVE fijado a '{0}'." -f $KeepAlive) -ForegroundColor Green
        }
    }
    Write-Host ("OLLAMA_KEEP_ALIVE actual: {0}" -f $effectiveKeep) -ForegroundColor Cyan
    Write-Host "Aviso: Ollama debe reiniciarse para aplicar OLLAMA_KEEP_ALIVE (Quit + ollama serve)." -ForegroundColor Yellow
    if ($effectiveKeep -eq "-1") {
        Write-Host "Aviso: KeepAlive '-1' mantiene el modelo siempre en VRAM: solo si sobra VRAM y usa 1 modelo." -ForegroundColor Yellow
    }

    # --- 3. Firewall: Private LAN rule + Tailscale-scoped rule (same names as Exponer script) ---
    Write-Host ("Paso 3/5: Verificando reglas de firewall (TCP {0})..." -f $Port) -ForegroundColor Cyan
    $ruleName = "Ollama LAN TCP {0}" -f $Port
    try {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Host ("La regla '{0}' ya existe. Sin duplicados." -f $ruleName) -ForegroundColor Green
        } elseif ($PSCmdlet.ShouldProcess("Regla firewall '$ruleName'", "Crear regla inbound TCP $Port perfil Private")) {
            try {
                New-NetFirewallRule -DisplayName $ruleName `
                    -Description "Permite acceso LAN a Ollama (solo redes privadas). Gestionado por Emparejar-Ollama-USB.ps1 / Exponer-Ollama-Servidor.ps1" `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                    -Profile Private -ErrorAction Stop | Out-Null
                Write-Host ("Regla '{0}' creada (solo perfil Private)." -f $ruleName) -ForegroundColor Green
            } catch {
                Write-Host ("Aviso: no se pudo crear la regla (ejecute como Admin): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host ("Aviso en firewall: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    $tailscaleIp = ""
    $magicDns = ""
    if ($ModoTailscale) {
        $tsCmd = Get-Command "tailscale" -ErrorAction SilentlyContinue
        if ($null -eq $tsCmd) {
            Write-Host "Aviso: 'tailscale' no esta en el PATH." -ForegroundColor Yellow
            Write-Host "Instale Tailscale desde https://tailscale.com/download, haga 'tailscale login' y repita -Modo Responder." -ForegroundColor Yellow
        } else {
            try {
                $tailscaleIp = (& tailscale ip --ipv4 2>&1 | Out-String).Trim().Split("`n")[0].Trim()
                Write-Host ("IP Tailscale detectada: {0}" -f $tailscaleIp) -ForegroundColor Green
            } catch {
                Write-Host ("Aviso: 'tailscale ip' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            try {
                $tsStatus = & tailscale status 2>&1 | Out-String
                $m = [regex]::Match($tsStatus, '([A-Za-z0-9-]+\.[A-Za-z0-9-]*tail[A-Za-z0-9-]*\.ts\.net)')
                if ($m.Success) {
                    $magicDns = $m.Groups[1].Value
                    Write-Host ("MagicDNS detectado: {0}" -f $magicDns) -ForegroundColor Green
                } else {
                    Write-Host "Aviso: no se detecto hostname MagicDNS en 'tailscale status'." -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("Aviso: 'tailscale status' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            if ([string]::IsNullOrWhiteSpace($tailscaleIp) -or $tailscaleIp -notlike "100.*") {
                Write-Host "Aviso: sin IP 100.x valida. Verifique 'tailscale login' y 'tailscale status'." -ForegroundColor Yellow
            }
        }
        $tsRuleName = "Ollama Tailscale TCP {0}" -f $Port
        $tsRange = "100.64.0.0/10"
        try {
            $existingTs = Get-NetFirewallRule -DisplayName $tsRuleName -ErrorAction SilentlyContinue
            if ($null -ne $existingTs) {
                Write-Host ("La regla '{0}' ya existe. Sin duplicados." -f $tsRuleName) -ForegroundColor Green
            } elseif ($PSCmdlet.ShouldProcess("Regla firewall '$tsRuleName'", "Crear regla inbound TCP $Port limitada a $tsRange")) {
                try {
                    New-NetFirewallRule -DisplayName $tsRuleName `
                        -Description "Permite Ollama solo desde la red Tailscale (100.64.0.0/10). Nunca abrir a Public/internet." `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                        -RemoteAddress $tsRange -Profile Any -ErrorAction Stop | Out-Null
                    Write-Host ("Regla '{0}' creada (solo {1})." -f $tsRuleName, $tsRange) -ForegroundColor Green
                } catch {
                    Write-Host ("Aviso: no se pudo crear la regla Tailscale (ejecute como Admin): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host ("Aviso en firewall Tailscale: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # --- 4. Restart reminder (non-interactive: brief pause, then verify) ---
    Write-Host "Paso 4/5: Ollama debe reiniciarse para aplicar OLLAMA_HOST..." -ForegroundColor Cyan
    $ollamaProc = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    if ($null -ne $ollamaProc) {
        Write-Host "Ollama esta en ejecucion: cierre (bandeja -> Quit) o Stop-Process -Name ollama -Force, luego 'ollama serve'." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    # --- 5. Probe endpoints + collect models ---
    Write-Host "Paso 5/5: Verificando endpoints y modelos..." -ForegroundColor Cyan
    $tagsUrl = "http://localhost:{0}/api/tags" -f $Port
    $modelsUrl = "http://localhost:{0}/v1/models" -f $Port
    $availableModels = @()
    try {
        $tagsResp = Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
        Write-Host ("OK: {0} responde." -f $tagsUrl) -ForegroundColor Green
        if ($null -ne (Get-PropValue $tagsResp "models")) {
            foreach ($m in $tagsResp.models) {
                $nm = Get-PropValue $m "name"
                if (-not [string]::IsNullOrWhiteSpace([string]$nm)) { $availableModels += [string]$nm }
            }
        }
    } catch {
        Write-Host ("FALLO: {0} no responde: {1}" -f $tagsUrl, $_.Exception.Message) -ForegroundColor Red
        Write-Host "Reinicie Ollama tras fijar OLLAMA_HOST y repita -Modo Responder." -ForegroundColor Yellow
    }
    try {
        $modelsResp = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
        Write-Host ("OK: {0} responde." -f $modelsUrl) -ForegroundColor Green
        if ($availableModels.Count -eq 0 -and $null -ne (Get-PropValue $modelsResp "data")) {
            foreach ($d in $modelsResp.data) {
                $id = Get-PropValue $d "id"
                if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $availableModels += [string]$id }
            }
        }
    } catch {
        Write-Host ("Aviso: /v1/models fallo ({0}); continuo con /api/tags." -f $_.Exception.Message) -ForegroundColor Yellow
    }
    if ($availableModels.Count -eq 0) {
        try {
            Write-Host "Intentando 'ollama list' como respaldo..." -ForegroundColor Cyan
            & ollama list 2>&1 | Out-String | Write-Host
        } catch {
            Write-Host ("Aviso: 'ollama list' fallo: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    $chosenModel = Select-BestModel -Available $availableModels -Hint $hintModel
    if ([string]::IsNullOrWhiteSpace($chosenModel)) {
        $chosenModel = "qwen2.5-coder:7b"
        Write-Host ("Sin modelos detectados; se sugiere '{0}'. Instale uno: ollama pull {0}" -f $chosenModel) -ForegroundColor Yellow
    } else {
        Write-Host ("Modelo elegido: {0}" -f $chosenModel) -ForegroundColor Green
    }

    # --- Build + write respuesta.json (no secrets: Ollama has no auth) ---
    $connectHost = $tailscaleIp
    if ([string]::IsNullOrWhiteSpace($connectHost) -or $connectHost -notlike "100.*") {
        if (-not [string]::IsNullOrWhiteSpace($magicDns)) { $connectHost = $magicDns }
    }
    if ([string]::IsNullOrWhiteSpace($connectHost)) { $connectHost = "IP_TAILSCALE_NO_DETECTADA" }
    $baseUrl = "http://{0}:{1}/v1" -f $connectHost, $Port
    $providerName = "ollama-remoto"
    $snippetNode = [PSCustomObject]@{
        npm     = "@ai-sdk/openai-compatible"
        name    = "Ollama Remoto (Tailscale)"
        options = [PSCustomObject]@{ baseURL = $baseUrl }
        models  = [PSCustomObject]@{}
    }
    $snippetNode.models | Add-Member -MemberType NoteProperty -Name $chosenModel -Value (@{ name = "$chosenModel (remoto)" })
    $respuesta = [PSCustomObject]@{
        version             = $BundleVersion
        serverId            = ("{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format "yyyyMMdd-HHmmss"))
        fecha               = (Get-Date -Format "o")
        tailscaleIp100x     = $tailscaleIp
        magicDns            = $magicDns
        puerto              = $Port
        modelosDisponibles  = $availableModels
        modeloElegido       = $chosenModel
        baseURL             = $baseUrl
        providerName        = $providerName
        keepAlive           = $effectiveKeep
        snippetJson         = $snippetNode
        apiKey              = ""
        authAdvertencia     = "Ollama no usa autenticacion: no se incluye ningun secreto. Campo apiKey reservado para futuro."
        instruccionesCliente = "Lleve el USB al cliente y ejecute: Emparejar-Ollama-USB.ps1 -Modo Aplicar"
    }
    if ($PSCmdlet.ShouldProcess($outFile, "Escribir respuesta de emparejamiento")) {
        $respuesta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFile -Encoding UTF8
        Write-Host ("Respuesta escrita: {0}" -f $outFile) -ForegroundColor Green
    }
    Write-Host "Devuelva este USB al cliente y alla ejecute:" -ForegroundColor Cyan
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar' -ForegroundColor Green
    exit 0
}

# ============================================================
# MODO 3: Aplicar (PC cliente) — apply respuesta.json to opencode.json
# ============================================================
if ($Modo -eq "Aplicar") {
    Write-Host "Modo Aplicar: buscando respuesta en el USB (vale cualquier letra de unidad)..." -ForegroundColor Cyan
    $pairingDir = Resolve-PairingDir -ExplicitUsb $UsbPath -Create $false -MarkerFile $RespuestaFile
    if ([string]::IsNullOrWhiteSpace($pairingDir)) { exit 1 }
    $inFile = Join-Path $pairingDir $RespuestaFile
    try {
        $rawIn = Get-Content -LiteralPath $inFile -Raw -Encoding UTF8
        $resp = $rawIn | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host ("ERROR: respuesta corrupta o ilegible: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Regenere en el servidor con -Modo Responder." -ForegroundColor Yellow
        exit 1
    }
    $errResp = Test-RespuestaSchema $resp
    if (-not [string]::IsNullOrWhiteSpace($errResp)) {
        Write-Host ("ERROR: respuesta invalida: {0}" -f $errResp) -ForegroundColor Red
        exit 1
    }
    $rHost = [string](Get-PropValue $resp "tailscaleIp100x")
    if ([string]::IsNullOrWhiteSpace($rHost) -or $rHost -notlike "100.*") {
        $rHost = [string](Get-PropValue $resp "magicDns")
    }
    if ([string]::IsNullOrWhiteSpace($rHost)) {
        Write-Host "ERROR: la respuesta no trae IP 100.x ni MagicDNS validos." -ForegroundColor Red
        Write-Host "En el servidor: verifique 'tailscale login', 'tailscale status' y repita -Modo Responder." -ForegroundColor Yellow
        exit 1
    }
    $rPort = [int](Get-PropValue $resp "puerto")
    if ($rPort -le 0) { $rPort = 11434 }
    $rModel = [string](Get-PropValue $resp "modeloElegido")
    $rBase = [string](Get-PropValue $resp "baseURL")
    $rProvider = [string](Get-PropValue $resp "providerName")
    if ([string]::IsNullOrWhiteSpace($rProvider)) { $rProvider = "ollama-remoto" }
    Write-Host ("Servidor: {0}:{1}  Modelo: {2}" -f $rHost, $rPort, $rModel) -ForegroundColor Green
    $rKeepAlive = [string](Get-PropValue $resp "keepAlive")
    if (-not [string]::IsNullOrWhiteSpace($rKeepAlive)) {
        Write-Host ("KeepAlive del servidor: {0} (informativo; vive en el servidor)." -f $rKeepAlive) -ForegroundColor Cyan
    }

    # --- Validate -TimeoutMs (>=60000, or 0=false to disable with confirmation) ---
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

    # --- Connectivity test (warn + continue so the config is still left ready) ---
    $tagsUrl = "http://{0}:{1}/api/tags" -f $rHost, $rPort
    Write-Host ("Probando {0} ..." -f $tagsUrl) -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Write-Host "OK: el servidor responde." -ForegroundColor Green
    } catch {
        Write-Host ("AVISO: sin conexion a {0}: {1}" -f $tagsUrl, $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "Se aplicara la configuracion igualmente; luego revise en orden:" -ForegroundColor Yellow
        Write-Host "  1. Tailscale UP en ambas PCs: 'tailscale status' debe mostrar ambos nodos." -ForegroundColor Yellow
        Write-Host "  2. Misma tailnet/cuenta; pruebe 'tailscale ping $rHost'." -ForegroundColor Yellow
        Write-Host "  3. Servidor: OLLAMA_HOST=0.0.0.0:$rPort y Ollama reiniciado." -ForegroundColor Yellow
        Write-Host "  4. Firewall servidor: regla 'Ollama Tailscale TCP $rPort' acotada a 100.64.0.0/10." -ForegroundColor Yellow
        Write-Host "  5. Fallback SSH: ssh -N -L 11434:localhost:11434 usuario@servidor y re-aplique con -UsbPath." -ForegroundColor Yellow
    }

    # --- Resolve + backup opencode.json ---
    if ([string]::IsNullOrWhiteSpace($OpencodeJsonPath)) {
        $OpencodeJsonPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    }
    Write-Host ("Archivo objetivo: {0}" -f $OpencodeJsonPath) -ForegroundColor Cyan
    if (Test-Path -LiteralPath $OpencodeJsonPath) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupPath = "{0}.bak-{1}" -f $OpencodeJsonPath, $stamp
        if ($PSCmdlet.ShouldProcess($OpencodeJsonPath, "Crear backup en $backupPath")) {
            Copy-Item -LiteralPath $OpencodeJsonPath -Destination $backupPath -Force
            Write-Host ("Backup creado: {0}" -f $backupPath) -ForegroundColor Green
        }
    }
    $config = $null
    if (Test-Path -LiteralPath $OpencodeJsonPath) {
        try {
            $raw = Get-Content -LiteralPath $OpencodeJsonPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { $config = New-Object PSObject }
            else { $config = $raw | ConvertFrom-Json -ErrorAction Stop }
        } catch {
            Write-Host ("ERROR: opencode.json existe pero no es JSON valido: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Restaure desde el .bak o corrija el JSON antes de reintentar." -ForegroundColor Yellow
            exit 1
        }
    } else {
        $config = New-Object PSObject
        Add-Member -InputObject $config -MemberType NoteProperty -Name '$schema' -Value "https://opencode.ai/config.json"
        Write-Host "El archivo no existe; se creara uno minimo valido." -ForegroundColor Yellow
    }
    if ($null -eq (Get-PropValue $config "provider")) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name "provider" -Value (New-Object PSObject)
    }
    $label = "Ollama Remoto (Tailscale)"
    if (-not $ModoTailscale) { $label = "Ollama Remoto (LAN)" }
    # Merge with existing provider node when present: preserve apiKey/headers/models.
    $existingProvider = Get-PropValue $config.provider $rProvider
    $providerNode = New-Object PSObject
    Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "npm" -Value "@ai-sdk/openai-compatible"
    Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "name" -Value $label
    $optionsNode = New-Object PSObject
    Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "baseURL" -Value $rBase
    if ($null -ne $existingProvider) {
        $existingOptions = Get-PropValue $existingProvider "options"
        if ($null -ne $existingOptions) {
            foreach ($op in @($existingOptions.PSObject.Properties)) {
                if ($op.Name -eq "baseURL" -or $op.Name -eq "timeout") { continue }
                Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name $op.Name -Value $op.Value
            }
        }
    }
    if ($timeoutDisabled) {
        Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "timeout" -Value $false
    } else {
        Add-Member -InputObject $optionsNode -MemberType NoteProperty -Name "timeout" -Value $timeoutValue
    }
    Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "options" -Value $optionsNode
    $modelsNode = New-Object PSObject
    if ($null -ne $existingProvider) {
        $existingModels = Get-PropValue $existingProvider "models"
        if ($null -ne $existingModels) {
            foreach ($mp in @($existingModels.PSObject.Properties)) {
                Add-Member -InputObject $modelsNode -MemberType NoteProperty -Name $mp.Name -Value $mp.Value
            }
        }
    }
    Add-Member -InputObject $modelsNode -MemberType NoteProperty -Name $rModel -Value (@{ name = "$rModel (remoto)" }) -Force
    Add-Member -InputObject $providerNode -MemberType NoteProperty -Name "models" -Value $modelsNode
    if ($PSCmdlet.ShouldProcess($OpencodeJsonPath, "Insertar/actualizar provider '$rProvider'")) {
        Add-Member -InputObject $config.provider -MemberType NoteProperty -Name $rProvider -Value $providerNode -Force
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
    Write-Host ("Modelo configurado: {0}/{1}  ->  {2}" -f $rProvider, $rModel, $rBase) -ForegroundColor Green
    Write-Host "Verificando con 'opencode models'..." -ForegroundColor Cyan
    try {
        & opencode models 2>&1 | Out-String | Write-Host
    } catch {
        Write-Host ("Aviso: 'opencode models' no pudo ejecutarse: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "Ejecute manualmente:  opencode models" -ForegroundColor Yellow
    }
    Write-Host "Listo: ya puede usar el modelo remoto en opencode." -ForegroundColor Green
    exit 0
}

# ============================================================
# MODO 4: Limpiar — undo what Responder/Exponer created
# ============================================================
if ($Modo -eq "Limpiar") {
    Write-Host "Modo Limpiar: deshaciendo lo creado por Responder/Exponer..." -ForegroundColor Cyan
    $desiredHost = "0.0.0.0:{0}" -f $Port

    # --- 1. User-level OLLAMA_HOST (only when it matches, else confirm) ---
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
        if ($Force) {
            $borrar = $true
        } else {
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

    # --- 1b. User-level OLLAMA_KEEP_ALIVE set by Responder/Exponer (confirm unless -Force) ---
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

    # --- 2. Firewall rules with exact DisplayNames (idempotent) ---
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

    # --- 3. USB bundle (opt-in only) ---
    if ($LimpiarUSB) {
        $pairingDir = Resolve-PairingDir -ExplicitUsb $UsbPath -Create $false -MarkerFile ""
        if ([string]::IsNullOrWhiteSpace($pairingDir)) {
            Write-Host "USB: no se encontro carpeta para limpiar." -ForegroundColor Yellow
        } elseif (-not (Test-Path -LiteralPath $pairingDir)) {
            Write-Host ("USB: no existe '{0}'. Ya limpio." -f $pairingDir) -ForegroundColor Green
        } elseif ($PSCmdlet.ShouldProcess($pairingDir, "Borrar carpeta ollama-pairing del USB")) {
            Remove-Item -LiteralPath $pairingDir -Recurse -Force -ErrorAction Stop
            Write-Host ("Quitada: carpeta USB '{0}'." -f $pairingDir) -ForegroundColor Green
        }
    } else {
        Write-Host "USB: se deja intacto (use -LimpiarUSB para borrar ollama-pairing)." -ForegroundColor Cyan
    }

    # --- 4. Summary of what stays ---
    Write-Host "Queda (no se toca): Ollama instalado, modelos descargados, opencode.json." -ForegroundColor Cyan
    Write-Host "Limpieza terminada. Reinicie Ollama (Quit + ollama serve) para aplicar." -ForegroundColor Green
    exit 0
}
