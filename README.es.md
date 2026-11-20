<p align="center"><img src="docs/banner.png" alt="SaySo" width="720"></p>

<p align="center"><em><a href="README.md">English</a> · Español</em></p>

**SaySo** es una app nativa de macOS que convierte tu voz en acciones. Mantén una tecla, habla,
y un agente de IA hace el resto: te responde en pantalla, escribe en tus chats de Telegram,
programa tareas y trabaja dentro de su propia máquina Linux, nunca en tu Mac. Todo lo que sale
del Mac sigue las reglas que tú pones, y pregunta antes cuando así lo quieres.

- 🎙️ **Dictado local**: mantén ⌥ (o el atajo que elijas) y Whisper transcribe en tu Mac, o pasa a una conversación continua con el agente
- 💬 **Telegram, de dos formas**: habla con el agente desde tu propio bot y, si quieres, deja que lea, busque, responda y envíe desde tu cuenta (TDLib), notas de voz y archivos incluidos
- 🐧 **Una máquina Linux aislada** (Virtualization.framework) donde el agente ejecuta comandos, instala herramientas, navega por la web y transcribe audio
- 🧩 **Plugins** sobre MCP, y complementos propios del agente dentro de la máquina Linux
- ⏰ **Tareas programadas** con destinatarios, calendario de cualquier día y opción de enviar sin preguntar
- 🧠 **Memoria editable**: notas marcadas como instrucciones o datos, presentes en cada conversación
- 🛡️ **Permisos y protecciones**: Permitir / Preguntar / Nunca por acción, secretos en el Llavero y ocultados antes de llegar al modelo, y revisión de las acciones hacia fuera cuando el agente ha leído contenido de terceros, con un clasificador local de inyecciones opcional
- 🔌 **Cualquier modelo**: Claude, OpenAI, OpenRouter, Grok, o uno local con Ollama o LM Studio
- 🌍 Español, inglés, gallego, francés y portugués

<p align="center">
  <img src="docs/screenshots/modular/inicio.png" alt="Inicio" width="420">
  <img src="docs/screenshots/modular/tareas.png" alt="Tareas programadas" width="420">
</p>

## 🚀 Primeros pasos

Necesitas **macOS 14 o posterior en un Mac con Apple Silicon** y una cuenta de un proveedor de
modelos (o un modelo local).

1. 📥 Descarga el último `SaySo-x.y.z.dmg` de [Releases](https://github.com/Pepebits/sayso/releases). Está firmado y notarizado.
2. 📂 Arrastra SaySo a Aplicaciones y ábrelo. La guía de bienvenida pide el micrófono y la Supervisión de entrada, y te lleva por el resto.
3. 🤖 Opcional: crea un bot con [@BotFather](https://t.me/BotFather) y pega su token en **Telegram**, e inicia sesión con tu cuenta si quieres que el agente trabaje con tus chats. La cuenta necesita tu propio `api_id` y `api_hash` de [my.telegram.org](https://my.telegram.org).

## 🛠️ Compilar desde el código

Hace falta Xcode 16 o posterior (Swift 6).

```bash
git clone https://github.com/Pepebits/sayso.git
cd sayso
scripts/make-app.sh          # crea build/SaySo.app (debug)
open build/SaySo.app
```

`scripts/make-app.sh release` compila la versión de lanzamiento. `scripts/release.sh` la firma
con Developer ID, la notariza y crea el DMG; la cabecera del script dice lo que necesita la
primera vez.

## 🧪 Tests

```bash
swift test
```

`scripts/check-strings.py <código>` comprueba que una traducción tiene todas las claves y huecos
de la inglesa.

## 📚 Documentación

- 🗺️ **[Plan y estado](docs/PLAN.md)**: funciones, fases y qué está comprobado
- 🧭 **[Decisiones de arquitectura](docs/adr/README.md)**: por qué app nativa, máquina Linux, TDLib, un único motor de permisos…

## 🔒 Privacidad

El dictado se transcribe en tu Mac. Las conversaciones, la memoria, las tareas y el registro de
actividad se guardan en local en SQLite, y los secretos en el Llavero. Al proveedor del modelo
le llega lo que le dices al agente y lo que leen sus herramientas para esa petición. SaySo no
tiene servidor ni envía telemetría.

## 📄 Licencia

[MIT](LICENSE) © Pepebits. Los componentes de terceros y sus licencias están en
[ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt).
