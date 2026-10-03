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
| 🔊 **Solo audio del sistema** | Un *process tap* de CoreAudio intercepta lo que suena en Spotify, Music o el navegador. **Nunca escucha el micrófono** y no hace falta ningún driver de terceros. |
| 🎚️ **Análisis FFT** | Ventana de 2048 muestras con ventana de Hamming y solapamiento del 50 %, vía `Accelerate` / vDSP. |
| 🥁 **Detección de beats** | Energía instantánea contra media móvil de ~1 s en la banda **0 – 250 Hz**, con umbral y tiempo de espera configurables. |
| 🎨 **Colores de Spotify** | Opcional: muestrea la ventana de Spotify y deriva los colores del glow del fondo que Spotify calcula a partir de la portada. Requiere permiso de Grabación de pantalla. |
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

- **macOS 14.4 (Sonoma) o posterior** — es la versión en la que la API de
  *process taps* de CoreAudio es utilizable.
- Xcode 15.3 o posterior
- Nada más: **no requiere BlackHole, Soundflower ni ningún driver de audio**.

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

1. Lanza nLight. La primera vez macOS pedirá permiso para **capturar el audio
   del sistema**: acéptalo.
2. Pon música en cualquier app.
3. Haz clic en el 💡 de la barra de menús para ajustar:
   - **Activar / desactivar brillo** (`⌘L` con el menú abierto)
   - **Intensidad** — cuánto responde el brillo al nivel de graves
   - **Grosor** — anchura máxima del halo en píxeles
   - **Sensibilidad al beat** — cuánto debe destacar un golpe sobre la media
     para contar como beat
   - **Seguir los colores de Spotify** — ver abajo
   - **Color superior / inferior** y **Color izquierda / derecha**
   - **Fuente de audio** — salida por defecto del sistema, o unos altavoces /
     auriculares concretos si tienes varios

El brillo solo aparece cuando hay señal: en silencio los bordes se apagan solos.

### Seguir los colores de Spotify

Con esta opción activada, nLight toma el color del glow de la propia ventana de
Spotify en vez de los colores guardados:

1. Localiza la ventana de Spotify con ScreenCaptureKit (solo esa ventana, nunca
   el resto de la pantalla) y captura una miniatura de 64×64 una vez por segundo.
2. Calcula el **tono dominante** por histograma, no por media: promediar los
   píxeles de una portada da siempre un gris parduzco, mientras que el tono más
   repetido es justo el que Spotify usa de fondo en el modo letra. Los píxeles
   grises y el texto blanco quedan descartados, y los más saturados pesan más.
3. Deriva la pareja final: el tono dominante para los bordes superior e inferior,
   y un **tono análogo (+32°)** para los laterales, que armoniza en lugar de
   competir. Saturación y brillo se elevan a un mínimo para que el glow se vea.
4. Funde el cambio poco a poco, así que al cambiar de canción el color se
   desplaza suavemente en vez de saltar.

Requiere permiso de **Grabación de pantalla** (Ajustes del Sistema → Privacidad y
seguridad). Es un permiso más intrusivo que el de audio, por eso la opción viene
desactivada: solo se usa si la enciendes. Tus colores manuales se conservan y
vuelven a mandar en cuanto la apagas.

### Cómo captura el audio del sistema

nLight usa la API de **process taps de CoreAudio** (macOS 14.4+):

1. `AudioHardwareCreateProcessTap` crea un tap global y **privado** sobre todos
   los procesos, con `muteBehavior = .unmuted`: el audio sigue sonando en tus
   altavoces exactamente igual.
2. `AudioHardwareCreateAggregateDevice` monta un dispositivo agregado privado
   que combina tu salida real con ese tap. Al ser privado no aparece en Ajustes
   de Sonido ni cambia la salida por defecto.
3. Un `AudioDeviceIOProc` sobre ese agregado recibe las muestras ya mezcladas en
   estéreo, que nLight reduce a mono y pasa a la FFT.

Consecuencias prácticas:

- **El micrófono nunca se toca.** Un tap solo ve audio de reproducción; si hablas
  o aplaudes, el glow no se inmuta.
- **Sin drivers.** No hay que instalar BlackHole ni recablear la salida del
  sistema en Configuración de Audio MIDI.
- Si cambias de altavoces a auriculares, nLight lo detecta con un listener sobre
  `kAudioHardwarePropertyDefaultOutputDevice` y reconstruye el tap solo.

---

## Arquitectura

```
nLight/
├── main.swift                 Arranque de NSApplication
├── AppDelegate.swift          Barra de menús, controles y coordinación
├── AudioManager.swift         Process tap de CoreAudio + FFT (vDSP) + beats
├── ColorSampler.swift         Muestreo de la ventana de Spotify (ScreenCaptureKit)
├── GlowWindow.swift           Ventanas overlay transparentes + GlowController
├── GlowView.swift             Dibujo de los 4 bordes con NSGradient
├── PreferencesManager.swift   Wrapper de UserDefaults
├── Info.plist                 LSUIElement + permiso de captura de audio
└── nLight.entitlements        Captura de audio bajo hardened runtime
```

**Flujo de datos:**

```
process tap ─IOProc─▶ buffer circular ─▶ Hamming ─▶ vDSP_fft_zrip ─▶ magnitudes
                                                                        │
                        beat ◀── energía 0-250 Hz vs. media móvil ◀──────┤
                                                                        │
   GlowView ◀── suavizado 0.15 @60 fps ◀── nivel normalizado ◀───────────┘
```

- El análisis corre en la cola de audio del IOProc: sin locks largos ni
  asignaciones de memoria dentro del callback.
- El dibujo corre a 60 fps en el hilo principal, leyendo la última instantánea
  del análisis y aplicando un suavizado exponencial (factor 0.15) para que el
  halo respire en lugar de parpadear.
- La normalización es adaptativa: un pico que decae lentamente ajusta la escala
  al volumen actual, así que la reacción es parecida con música fuerte o suave.

**Frameworks:** Accelerate, AVFoundation, CoreAudio, ScreenCaptureKit, AppKit.

---

## Solución de problemas

**El brillo no aparece nunca**
Comprueba en el menú la línea de estado: si dice *«Sin captura de audio»* o
muestra un aviso ⚠️, revisa el permiso de captura de audio en Ajustes del
Sistema → Privacidad y seguridad, y vuelve a activar el brillo. Los errores de
CoreAudio se registran además en Consola con el prefijo `[nLight]`.

**El brillo no reacciona aunque suene la música**
Comprueba que la app que reproduce va a la misma salida que nLight está
interceptando (*Fuente de audio* en el menú). Si acabas de cambiar de
dispositivo, desactiva y reactiva el brillo.

**Los colores de Spotify no cambian**
El propio item del menú dice por qué: si Spotify no está abierto, si falta el
permiso de Grabación de pantalla, o si la portada no tiene un color dominante
claro (las carátulas en blanco y negro no dan tono). Tras conceder el permiso hay
que reiniciar nLight, que es como macOS trata ese permiso.

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
