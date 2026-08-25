# nLight 💡

**Brillo reactivo al audio en los cuatro bordes de tu pantalla, para macOS.**

nLight vive en la barra de menús, escucha el audio en tiempo real, calcula una
FFT sobre la señal y hace latir un halo de luz en los bordes de la pantalla al
ritmo de los graves de la música. Es el equivalente en software de una tira LED
ambilight detrás del monitor, sin hardware.

Proyecto personal de código abierto bajo licencia MIT. Sin telemetría, sin
cuentas, sin red: el audio se analiza en memoria y nunca sale de tu Mac.

---

## Características

| | |
|---|---|
| 🎚️ **Análisis FFT** | Ventana de 2048 muestras con ventana de Hamming y solapamiento del 50 %, vía `Accelerate` / vDSP. |
| 🥁 **Detección de beats** | Energía instantánea contra media móvil de ~1 s en la banda **0 – 250 Hz**, con umbral y tiempo de espera configurables. |
| 🌈 **Cuatro bordes** | Superior e inferior con un color; izquierda y derecha con otro. Rojo y azul por defecto. |
| 🕹️ **Menú de control** | Toggle On/Off, deslizadores de intensidad, grosor y sensibilidad, y selector de color con presets o el color picker del sistema. |
| 🖥️ **Multi-pantalla** | Una ventana overlay por pantalla, con reconstrucción automática al conectar o desconectar monitores. |
| 💾 **Preferencias persistentes** | Todo se guarda en `UserDefaults` y se restaura al arrancar. |
| 🪶 **Ligero e invisible** | `LSUIElement`: sin icono en el Dock, sin ventanas, sin capturar clics. |

### Valores por defecto

| Ajuste | Rango | Por defecto |
|---|---|---|
| Intensidad | 0.1× – 2.0× | 1.0× |
| Grosor | 10 – 80 px | 40 px |
| Sensibilidad al beat | 1.05 – 2.5 | 1.35 |
| Color superior / inferior | libre | rojo |
| Color izquierda / derecha | libre | azul |
| Suavizado de animación | fijo | 0.15 |

---

## Requisitos

- macOS 12 (Monterey) o posterior
- Xcode 14 o posterior
- Opcional pero muy recomendable: un dispositivo de audio *loopback* como
  [BlackHole](https://github.com/ExistentialAudio/BlackHole) para capturar el
  audio **del sistema** en lugar del micrófono.

---

## Compilar y ejecutar

```bash
git clone https://github.com/niluhh/nlight.git
cd nlight
open nLight.xcodeproj
```

En Xcode: **⌘B** para compilar y **⌘R** para ejecutar. Aparecerá el icono 💡 en
la barra de menús.

Desde la terminal, sin abrir Xcode:

```bash
xcodebuild -project nLight.xcodeproj -scheme nLight -configuration Release build
```

El binario queda en `~/Library/Developer/Xcode/DerivedData/nLight-*/Build/Products/Release/nLight.app`.

> El proyecto está configurado con firma ad-hoc (`CODE_SIGN_IDENTITY = "-"`),
> así que compila y se ejecuta localmente sin cuenta de desarrollador de pago.

---

## Cómo usarlo

1. Lanza nLight. La primera vez macOS pedirá permiso de **micrófono**: acéptalo
   (es el permiso que cubre toda captura de audio de entrada, incluidos los
   dispositivos virtuales).
2. Pon música.
3. Haz clic en el 💡 de la barra de menús para ajustar:
   - **Activar / desactivar brillo** (`⌘L` con el menú abierto)
   - **Intensidad** — cuánto responde el brillo al nivel de graves
   - **Grosor** — anchura máxima del halo en píxeles
   - **Sensibilidad al beat** — cuánto debe destacar un golpe sobre la media
     para contar como beat
   - **Color superior / inferior** y **Color izquierda / derecha**
   - **Fuente de audio** — entrada por defecto del sistema o un dispositivo concreto

El brillo solo aparece cuando hay señal: en silencio los bordes se apagan solos.

### Capturar el audio del sistema (no el micrófono)

macOS no deja grabar la salida de audio directamente. La solución estándar es un
driver de loopback:

1. Instala BlackHole 2ch:
   ```bash
   brew install blackhole-2ch
   ```
2. Abre **Configuración de Audio MIDI** → **+** → **Crear dispositivo de salida
   múltiple**, y marca tus altavoces junto con *BlackHole 2ch*.
3. Selecciona ese dispositivo múltiple como salida del sistema (así sigues
   oyendo la música).
4. En nLight, elige **Fuente de audio → BlackHole 2ch**.

---

## Arquitectura

```
nLight/
├── main.swift                 Arranque de NSApplication
├── AppDelegate.swift          Barra de menús, controles y coordinación
├── AudioManager.swift         AVAudioEngine + FFT (vDSP) + detección de beats
├── GlowWindow.swift           Ventanas overlay transparentes + GlowController
├── GlowView.swift             Dibujo de los 4 bordes con NSGradient
├── PreferencesManager.swift   Wrapper de UserDefaults
├── Info.plist                 LSUIElement + permisos de audio
└── nLight.entitlements        Entrada de audio bajo hardened runtime
```

**Flujo de datos:**

```
AVAudioEngine ─tap─▶ buffer circular ─▶ Hamming ─▶ vDSP_fft_zrip ─▶ magnitudes
                                                                        │
                        beat ◀── energía 0-250 Hz vs. media móvil ◀──────┤
                                                                        │
   GlowView ◀── suavizado 0.15 @60 fps ◀── nivel normalizado ◀───────────┘
```

- El análisis corre en el hilo de audio en tiempo real: sin locks largos ni
  asignaciones de memoria dentro del *tap*.
- El dibujo corre a 60 fps en el hilo principal, leyendo la última instantánea
  del análisis y aplicando un suavizado exponencial (factor 0.15) para que el
  halo respire en lugar de parpadear.
- La normalización es adaptativa: un pico que decae lentamente ajusta la escala
  al volumen actual, así que la reacción es parecida con música fuerte o suave.

**Frameworks:** Accelerate, AVFoundation, CoreAudio, AppKit.

---

## Solución de problemas

**El brillo no aparece nunca**
Comprueba en el menú la línea de estado: si dice *«Sin captura de audio»* o
muestra un aviso ⚠️, revisa el permiso de micrófono en Ajustes del Sistema →
Privacidad y seguridad → Micrófono, y vuelve a activar el brillo.

**Reacciona a mi voz en vez de a la música**
Estás capturando el micrófono. Configura BlackHole como se explica arriba y
selecciónalo en *Fuente de audio*.

**El brillo late demasiado o demasiado poco**
Sube la **intensidad** para más respuesta y baja la **sensibilidad al beat** para
que dispare con golpes menos marcados (o al revés).

**No veo los bordes en una segunda pantalla**
nLight crea una ventana por pantalla y se reconstruye al detectar cambios. Si
acabas de conectar el monitor, abre y cierra el menú para forzar el refresco.

**El halo tapa la barra de menús o el Dock**
Es intencionado: el overlay se dibuja por encima para cubrir el borde completo.
No captura clics, así que puedes seguir usando lo que hay debajo con normalidad.
Baja el **grosor** si te molesta.

**«nLight no se puede abrir porque proviene de un desarrollador no identificado»**
Ocurre si mueves el `.app` a otro Mac. Compílalo tú mismo, o haz clic derecho →
*Abrir* la primera vez.

**Consumo de CPU**
Ronda el 1–3 % en Apple Silicon. Si te sobra, desactiva el brillo desde el menú:
eso detiene el motor de audio y el temporizador de dibujo por completo.

---

## Contribuir

Los *issues* y *pull requests* son bienvenidos. El CI de GitHub Actions compila
el proyecto en cada push, así que asegúrate de que `xcodebuild` pasa en local
antes de abrir una PR.

## Licencia

MIT — consulta [LICENSE](LICENSE).
