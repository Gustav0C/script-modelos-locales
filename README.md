# Usar un modelo local de otra PC en OpenCode

**Qué es esto:** usa la PC potente (servidor con Ollama) como cerebro, y tu PC (cliente con OpenCode) se conecta a ella por Tailscale. **Resultado:** escribes en OpenCode con un modelo remoto como `ollama-remoto/qwen2.5-coder:7b`.

> Si solo quieres que funcione, lee hasta **Uso fácil**. Lo demás es referencia.

## Qué necesito

1. **Servidor (PC con el modelo):** Ollama instalado + 1 modelo descargado (`ollama list` lo muestra).
2. **Cliente (tu PC):** OpenCode instalado.
3. **Ambas PCs:** Tailscale instalado, con `tailscale login` en la misma cuenta.
4. **Un USB:** para llevar la configuración de una PC a otra (no necesitan estar juntas en red).
5. Windows con PowerShell 5.1 (viene por defecto). No hay que instalar nada más.

## Paso 0 — Copiar todo al USB (una sola vez)

Ya lo hiciste con la opción 8, pero si repites:

1. Conecta el USB a tu PC.
2. Abre el menú (doble-click en `Abrir-Menu-Ollama.bat` o comando de abajo).
3. Elige `[8] Copiar todo al USB` → elige el número de tu USB → confirma con `s`.
4. Verás `Copiado: ...` y `Listo: 6 archivos en 'E:\'` (la letra cambia, es normal).

El USB debe quedar con estos 6 archivos en la raíz: `Abrir-Menu-Ollama.bat`, `Menu-Ollama.ps1`, `Emparejar-Ollama-USB.ps1`, `Exponer-Ollama-Servidor.ps1`, `Configurar-Opencode-Remoto.ps1`, `README.md`.

## Uso fácil — solo doble-click (recomendado)

No escribas comandos. En cada PC haz doble-click en `Abrir-Menu-Ollama.bat` del USB y usa números + `Enter`.

### Camino feliz en 3 pasos

**1. En tu PC (cliente): opción 1 Solicitar**

- Elige `[1]` → `Enter` para USB automático → `Enter` para omitir pista de modelo.
- Verás: `Solicitud escrita: E:\ollama-pairing\solicitud.json` y `Lleve este USB al servidor`.
- Lleva el USB físicamente a la otra PC.

**2. En la PC del modelo (servidor): opción 2 Responder**

- Elige `[2]` → `Enter` para puerto `11434` → `Enter` para KeepAlive `24h` (o escribe `5m`, `0`, `-1`).
- Verás en orden: `Ollama detectado`, `OLLAMA_HOST fijado a '0.0.0.0:11434'`, `OLLAMA_KEEP_ALIVE fijado a '24h'`, `Regla 'Ollama LAN TCP 11434' creada`, `IP Tailscale detectada: 100.x...`, `Modelo elegido: ...`, `Respuesta escrita: ...\respuesta.json` (incluye campo `keepAlive`).
- Si pide firewall/variables, acepta y si avisa `ejecute como Admin`, cierra y abre el menú como Administrador (click derecho → Ejecutar como administrador) y repite `[2]`.
- **Reinicia Ollama** cuando lo pida (icono bandeja → Quit, luego `ollama serve`): `OLLAMA_HOST` y `OLLAMA_KEEP_ALIVE` solo aplican tras reiniciar.
- Trae el USB de vuelta a tu PC.

**3. En tu PC (cliente): opción 3 Aplicar**

- Elige `[3]` → `Enter` para TimeoutMs `600000`.
- Verás: `Servidor: 100.x... Modelo: ...`, `OK: el servidor responde`, `Backup creado: ...opencode.json.bak-...`, `opencode.json actualizado`, `Timeout aplicado: 600000 ms`, `Listo: ya puede usar el modelo remoto`.
- Comprueba en OpenCode: elige el modelo `ollama-remoto/...` o corre `opencode models`.

### Las demás opciones del menú

- `[4] Limpiar` — deshace lo creado en esa PC (pregunta PC / USB / Ambos; también ofrece quitar `OLLAMA_KEEP_ALIVE`).
- `[5] Exponer servidor directo` — solo si ambas PCs están juntas (sin USB); pide KeepAlive (`24h` por defecto).
- `[6] Configurar cliente directo` — te pide la IP (100.x) y configura sin USB; pide TimeoutMs (`600000` por defecto).
- `[7] Diagnostico` — solo lee y muestra qué falla (no cambia nada): incluye `OLLAMA_KEEP_ALIVE` actual y `timeout` de `opencode.json`.
- `[0] Salir`.

## Qué hace cada archivo

| Archivo | Qué hace (1 línea) |
|---|---|
| `Abrir-Menu-Ollama.bat` | Doble-click que abre el menú; funciona con cualquier letra de USB (`%~dp0`). |
| `Menu-Ollama.ps1` | Menú 0–8 que muestra el comando exacto antes de correrlo; no pide Admin para abrirse. |
| `Emparejar-Ollama-USB.ps1` | Lleva la config en el USB: `Solicitar` → `Responder` (fija `OLLAMA_KEEP_ALIVE`, escribe `keepAlive` en `respuesta.json`) → `Aplicar` (pone `options.timeout`, preserva resto del JSON) (+ `Limpiar`). |
| `Exponer-Ollama-Servidor.ps1` | Prepara el servidor: fija `OLLAMA_HOST=0.0.0.0:11434` y `OLLAMA_KEEP_ALIVE=24h`, crea reglas firewall. |
| `Configurar-Opencode-Remoto.ps1` | Configura el cliente: prueba `http://SERVIDOR:11434/api/tags`, hace backup de `opencode.json` y agrega el provider `ollama-remoto` (`npm:@ai-sdk/openai-compatible`) con `options.timeout=600000` (preserva `baseURL`/`apiKey`/`headers`/modelos). |
| `README.md` | Esta guía. |

## Uso avanzado — sin USB (comandos copy-paste)

Solo si prefieres terminal. Todos probados en PS 5.1.

```powershell
# SERVIDOR (PC con Ollama) — exponer directo
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -Port 11434 -ModelHint "qwen2.5-coder:7b"
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -ModoTailscale
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -KeepAlive "24h"
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -KeepAlive "5m"
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -WhatIf

# CLIENTE (tu PC) — usa la IP 100.x que imprimió el servidor
curl.exe http://100.64.12.34:11434/api/tags
curl.exe http://100.64.12.34:11434/v1/models
powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34
powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34 -Port 11434 -Model "qwen2.5-coder:7b"
powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34 -ModoTailscale
powershell -NoProfile -ExecutionPolicy Bypass -File "Configurar-Opencode-Remoto.ps1" -RemoteHost 100.64.12.34 -TimeoutMs 600000
opencode models
```

```powershell
# USB por comandos (equivale al menú 1-2-3)
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Solicitar
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Solicitar -UsbPath "E:\" -ModelHint "qwen2.5-coder:7b"
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Responder
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Responder -KeepAlive "24h"
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Aplicar -TimeoutMs 600000

# Menú no interactivo (corre una vez y sale)
powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Diagnostico
powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Solicitar -UsbPath "E:\"
powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Exponer -Port 11434
powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Configurar -RemoteHost 100.64.12.34
powershell -NoProfile -ExecutionPolicy Bypass -File "Menu-Ollama.ps1" -Accion Limpiar -LimpiarUSB -UsbPath "E:\"
```

Notas: el puerto por defecto es `11434`. `-RemoteHost` acepta IP LAN (`192.168.x.x`), IP Tailscale (`100.x`) o MagicDNS (`mi-pc.tailXXXX.ts.net`). Para solo LAN sin Tailscale en USB usa `-ModoTailscale:$false`.

## Valores por defecto

| Parámetro | Default | Dónde | Valores válidos |
|---|---|---|---|
| `-KeepAlive` | `24h` | `Responder` / `Exponer` (servidor, var `OLLAMA_KEEP_ALIVE`) | `5m`, `0`, `-1`, `24h`... formato `Número+s/m/h`, o `-1`/`0` |
| `-TimeoutMs` | `600000` (10 min) | `Aplicar` / `Configurar` (cliente, `provider.ollama-remoto.options.timeout`) | entero `>=60000`, o `0` = `timeout:false` (desactivar, con confirmación) |

`solicitud.json` puede llevar `timeoutHint`, pero `Responder` lo ignora: el timeout es decisión del cliente y `keepAlive` es decisión del servidor.

> **Aviso `-1`:** `KeepAlive "-1"` mantiene el modelo siempre cargado en VRAM. Úselo solo si sobra VRAM y trabaja con 1 modelo; con varios modelos o VRAM justa prefiera `24h` o `5m`.

> **Aviso `timeout:false`:** `-TimeoutMs 0` escribe `options.timeout = false` (sin límite). Pide confirmación (`[s/N]`, o `-Force` para forzar). Úselo solo si un modelo lento supera los 10 min; en red inestable mejor subir a `900000` que desactivar.

## Limpiar (deshacer)

Desde el menú elige `[4]` y responde `1` (esta PC), `2` (solo USB) o `3` (ambos). O por comando:

```powershell
# Esta PC (quita OLLAMA_HOST + reglas firewall, no toca modelos ni opencode.json)
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar
# PC + USB
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar -LimpiarUSB -UsbPath "E:\"
# Simular sin cambiar nada / forzar borrado de OLLAMA_HOST personalizado
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File "Emparejar-Ollama-USB.ps1" -Modo Limpiar -Force
# Equivalente directo sin USB (en servidor)
powershell -NoProfile -ExecutionPolicy Bypass -File "Exponer-Ollama-Servidor.ps1" -Limpiar
```

No borra: Ollama instalado, modelos descargados, `opencode.json` (queda intacto; solo se le hizo backup `.bak-fecha` al aplicar).

## Problemas comunes

| Lo que ves | Qué hacer |
|---|---|
| `ollama no se reconoce` en tu PC (cliente) | Normal: Ollama solo debe estar en el servidor. En el cliente no lo necesitas. |
| `tailscale no está en el PATH` | Instala Tailscale desde https://tailscale.com/download en esa PC y haz `tailscale login` con la misma cuenta en ambas. |
| `localhost:11434 falla` en tu PC (cliente) | Normal: `localhost` solo funciona en el servidor. En el cliente usa la IP `100.x` del servidor. |
| SmartScreen: `Windows protegió su PC` al doble-click | Normal (el `.bat` no está firmado): elige `Más información` → `Ejecutar de todos modos`. |
| Antivirus bloquea el `.bat` | Click derecho → Propiedades → `Desbloquear` → Aceptar. El `.bat` es texto plano, ábrelo con Bloc de notas: no descarga nada. |
| `requiere Admin` / no se pudo crear/quitar regla firewall | Cierra el menú, click derecho en `Abrir-Menu-Ollama.bat` → Ejecutar como administrador, repite la acción. |
| `sin IP 100.x` / `tailscale login` | En esa PC corre `tailscale login`, luego `tailscale status` debe mostrar ambos nodos y `tailscale ip --ipv4` debe dar `100.x`. Repite `Responder`. |
| `No se detectó ningún USB` o la letra cambió (`E:` → `F:`) | Normal: la letra cambia entre PCs. Conecta el USB o pasa la letra a mano (`-UsbPath "F:\"`); `Aplicar` busca en todos los USB. |
| `Bundle corrupto / versión no soportada` | No edites los JSON a mano. Regenera: `Solicitar` en cliente o `Responder` en servidor. |
| Tras `Aplicar` no conecta | En orden: 1) `tailscale status` muestra ambas PCs, 2) `tailscale ping 100.x`, 3) servidor con `OLLAMA_HOST=0.0.0.0:11434` + Ollama reiniciado, 4) regla `Ollama Tailscale TCP 11434` acotada a `100.64.0.0/10`. Corre `[7] Diagnostico` en ambas. |
| Red privada vs pública | La regla LAN debe ser perfil `Private`, no `Public`. Ver con `Get-NetFirewallRule -DisplayName "Ollama LAN TCP 11434"`. La regla Tailscale va acotada a `100.64.0.0/10` porque ese adaptador suele verse como `Public`. |

## Seguridad

- **No expongas Ollama a internet:** no tiene autenticación, quien alcance el puerto `11434` puede usar tus modelos. Solo red privada o Tailscale (`100.64.0.0/10`).
- **Firewall acotado:** regla LAN solo perfil `Private` + regla Tailscale solo a `100.64.0.0/10`. Nunca abras perfil `Public` a internet. Quitar/crear reglas pide Admin.
- **USB sin secretos:** el USB solo lleva IPs, nombres de modelo y el snippet `ollama-remoto`; `apiKey` queda vacío porque Ollama no usa auth. Tu `opencode.json` original siempre queda respaldado como `.bak-fecha`.

## ¿Quieres aportar?

Este proyecto es open source (MIT). Tienes una idea, una mejora o un problema: abre un [issue](https://github.com/Gustav0C/script-modelos-locales/issues/new/choose) con la plantilla **Propuesta de idea / mejora** — no hace falta tocar código. Si prefieres contribuir código, lee [CONTRIBUTING.md](CONTRIBUTING.md) antes de abrir un PR.
