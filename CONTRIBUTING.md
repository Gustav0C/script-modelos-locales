# Cómo contribuir

Gracias por querer aportar. Este proyecto es pequeño y simple a propósito: scripts de PowerShell que emparejan OpenCode con un Ollama remoto por LAN, Tailscale o USB.

## Proponer una idea (la vía más fácil)

Cualquiera puede aportar ideas sin tocar código:

1. Abre un **Issue** con la plantilla *Propuesta de idea / mejora*.
2. Describe el **problema o contexto** (no hace falta proponer la solución perfecta).
3. Si ya tienes una propuesta concreta, inclúyela, pero no es obligatorio.

Las ideas se etiquetan como `idea`, se discuten en el issue y, si prosperan, se convierten en tareas. No hace falta pedir permiso para abrir un issue con una idea.

## Reportar un problema

- Si es un **fallo de seguridad** (algo que abre Ollama a una red no deseada), **no abras un issue público**: escribe a `gcanales58@gmail.com` o abre un issue privado. La seguridad de este proyecto importa porque los scripts tocan el firewall.
- Si es un bug normal, abre un issue con: qué hiciste, qué esperabas, qué pasó, y el resultado de `[7] Diagnostico`.

## Contribuir código (PR)

1. **Fork** el repo y crea una rama: `git checkout -b feat/descripcion-corta`.
2. Cambia lo mínimo necesario para resolver el problema. Este proyecto no crece por fama: si una mejora añade 3 scripts para un caso borde, primero abre un issue para discutirla.
3. Sigue las convenciones del proyecto:
   - PowerShell 5.1 (viene con Windows). No uses sintaxis de PS 7.
   - Mensajes de usuario en español, comentarios de código en inglés (como ya están).
   - Texto plano, sin dependencias externas: los scripts se copian a un USB y corren sin instalar nada.
4. Verifica **en una PC Windows real** que tu cambio funciona y no rompe los flujos USB, LAN y Tailscale.
5. Haz commit con mensajes convencionales, por ejemplo: `fix: preserve baseURL when updating provider` o `feat: add -KeepAlive switch to Responder`.
6. Abre el **Pull Request** describiendo qué cambia y por qué, y qué probaste.

## Límites que no se negocian

- **Nunca** abrir el firewall al perfil `Public`/internet.
- **Nunca** pedir credenciales, tokens o secretos en el USB o en `opencode.json` (Ollama no tiene auth; eso está por diseño).
- **Nunca** romper la compatibilidad con el menú `0–8` que la gente ya usa por doble-click.