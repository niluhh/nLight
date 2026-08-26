//
//  AudioManager.swift
//  nLight
//
//  Captura del audio de SALIDA del sistema mediante Core Audio Taps
//  (macOS 14.4+), FFT con Accelerate y detección de beats en el rango de
//  bajas frecuencias (0 - 250 Hz).
//
//  GARANTÍA DE DISEÑO: este archivo no contiene ninguna ruta de captura por
//  dispositivo de entrada. Un process tap solo observa audio de reproducción,
//  así que el micrófono es inalcanzable por construcción. Si el tap falla, la
//  captura se aborta y el error queda visible en el menú y en consola: nunca
//  hay repliegue silencioso a otra fuente.
//

import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

/// Dispositivo de salida de CoreAudio susceptible de ser interceptado.
struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Estado de cada paso de la cadena de captura, para el menú de diagnóstico.
/// Todos los campos se rellenan aunque el arranque falle a medias.
struct AudioDiagnostics {
    var authorization = "sin consultar"
    var targetDevice = "sin resolver"
    var tap = "sin crear"
    var format = "sin leer"
    var aggregate = "sin crear"
    var ioProc = "sin instalar"
    /// Cuántas veces ha entrado CoreAudio en el IOProc desde el último arranque.
    var callbackCount = 0
    var lastBufferCount = 0
    var lastFrameCount = 0
    /// RMS del último bloque mezclado a mono. Cero sostenido = stream equivocado.
    var lastRMS: Float = 0

    /// Resumen de una línea para el item de menú.
    var summary: String {
        if callbackCount == 0 { return "IOProc nunca llamado — \(ioProc)" }
        if lastRMS <= 0.000_01 { return "IOProc activo (\(callbackCount)) pero RMS 0 — stream sin audio" }
        return "Capturando · \(callbackCount) bloques · RMS \(String(format: "%.4f", lastRMS))"
    }
}

/// Instantánea del análisis de audio, consumida por la capa de dibujo.
struct AudioSnapshot {
    /// Nivel normalizado de graves (0...1).
    var bassLevel: Float = 0
    /// Nivel normalizado de toda la banda audible (0...1).
    var overallLevel: Float = 0
    /// `true` durante un breve instante después de detectar un golpe.
    var beat: Bool = false
}

final class AudioManager: NSObject {

    // MARK: - Configuración del análisis

    /// Tamaño de la FFT en muestras.
    static let fftSize = 2048
    /// Límite superior de la banda de graves analizada, en Hz.
    static let bassUpperHz: Float = 250
    /// Tiempo mínimo entre dos beats consecutivos, en segundos.
    private static let beatCooldown: CFTimeInterval = 0.12
    /// Cuánto tiempo permanece activo el flag de beat, en segundos.
    private static let beatHoldTime: CFTimeInterval = 0.09
    /// Número de ventanas guardadas para calcular la media móvil de energía.
    private static let energyHistoryLength = 43

    // MARK: - Estado público

    private(set) var isRunning = false
    /// Último error de arranque legible por el usuario, si lo hubo.
    private(set) var lastErrorDescription: String?

    /// Estado de cada paso de la cadena. Seguro de leer desde el hilo principal.
    var diagnostics: AudioDiagnostics {
        get { diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }; return diagnosticsStorage }
        set { diagnosticsLock.lock(); diagnosticsStorage = newValue; diagnosticsLock.unlock() }
    }

    private let diagnosticsLock = NSLock()
    private var diagnosticsStorage = AudioDiagnostics()

    /// Todo el logging del módulo lleva el mismo prefijo para poder filtrarlo
    /// en Consola con `[nLight]`.
    private func log(_ message: String) {
        NSLog("[nLight] %@", message)
    }

    /// Instantánea más reciente. Segura de leer desde el hilo principal.
    var snapshot: AudioSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        var current = latestSnapshot
        current.beat = CACurrentMediaTime() - lastBeatTime < AudioManager.beatHoldTime
        return current
    }

    // MARK: - Estado del tap

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AudioStreamBasicDescription?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    /// Cola serie sobre la que CoreAudio entrega los bloques capturados.
    private let ioQueue = DispatchQueue(label: "com.nlight.app.audio-tap", qos: .userInteractive)

    // MARK: - Estado del análisis

    private let stateLock = NSLock()

    private var latestSnapshot = AudioSnapshot()
    private var lastBeatTime: CFTimeInterval = -1

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?

    private var window: [Float]
    private var windowed: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]

    /// Buffer circular donde se acumulan las muestras hasta completar una ventana.
    private var sampleRing: [Float]
    private var ringWriteIndex = 0
    private var samplesSinceLastFFT = 0

    private var energyHistory: [Float] = []
    private var bassPeak: Float = 1e-4
    private var overallPeak: Float = 1e-4
    /// Frecuencia de muestreo REAL leída de `kAudioTapPropertyFormat`.
    /// Cero significa «todavía no hay formato válido»: mientras valga cero no se
    /// analiza nada, para que nunca se asuma una frecuencia que no es la del tap.
    private var sampleRate: Float = 0
    /// Copia local de la preferencia: el hilo de audio no debe tocar UserDefaults.
    private var beatSensitivity: Float = Float(PreferencesManager.Defaults.sensitivity)

    // MARK: - Ciclo de vida

    override init() {
        let size = AudioManager.fftSize
        log2n = vDSP_Length(log2(Float(size)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        realParts = [Float](repeating: 0, count: size / 2)
        imagParts = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        sampleRing = [Float](repeating: 0, count: size)

        super.init()

        vDSP_hamm_window(&window, vDSP_Length(size), 0)
        applyPreferences()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyPreferences),
            name: PreferencesManager.didChangeNotification,
            object: nil
        )
    }

    @objc private func applyPreferences() {
        let sensitivity = Float(PreferencesManager.shared.sensitivity)
        stateLock.lock()
        beatSensitivity = sensitivity
        stateLock.unlock()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Pide el permiso de captura de audio con el que macOS protege los process taps.
    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Arranque y parada

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastErrorDescription = nil
        diagnostics = AudioDiagnostics()

        log("──────── arranque de captura ────────")
        log("Build: process tap de CoreAudio (sin ninguna ruta de micrófono).")

        // Prioridad 3: el estado TCC se registra ANTES de tocar el tap, porque
        // un permiso denegado es la causa más probable de que el tap no entregue nada.
        logAuthorizationStatus()

        guard let device = resolveTargetDevice() else {
            fail("No se encontró ningún dispositivo de salida que interceptar.")
            return false
        }

        guard let deviceUID = AudioManager.stringProperty(kAudioDevicePropertyDeviceUID, of: device) else {
            fail("El dispositivo de salida no expone un UID.")
            return false
        }

        let deviceName = AudioManager.stringProperty(kAudioObjectPropertyName, of: device) ?? "(sin nombre)"
        diagnostics.targetDevice = "\(deviceName) [\(deviceUID)] id=\(device)"
        log("Dispositivo objetivo: «\(deviceName)» id=\(device) uid=\(deviceUID)")
        log("Canales de salida del objetivo: \(AudioManager.outputChannelCount(of: device))")

        guard createTap(), readTapFormat(), createAggregateDevice(around: deviceUID), startIO() else {
            log("El arranque falló: se desmonta todo. NO hay repliegue a ninguna otra fuente.")
            teardown()
            return false
        }

        observeDefaultOutputDevice()
        isRunning = true
        log("Captura activa sobre «\(deviceName)» a \(Int(sampleRate)) Hz.")
        log("Si en 2 s no aparecen líneas «IOProc», el agregado no está entregando audio.")
        return true
    }

    /// Registra el estado del permiso con el que macOS protege los process taps.
    private func logAuthorizationStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let text: String
        switch status {
        case .authorized: text = "concedido"
        case .denied: text = "DENEGADO — Ajustes → Privacidad y seguridad; sin esto el tap no entrega audio"
        case .restricted: text = "restringido por política del sistema"
        case .notDetermined: text = "sin determinar (aún no se ha pedido)"
        @unknown default: text = "desconocido (\(status.rawValue))"
        }
        diagnostics.authorization = text
        log("Permiso de captura de audio: \(text)")
    }

    func stop() {
        guard isRunning else { return }
        stopObservingDefaultOutputDevice()
        teardown()
        isRunning = false
        reset()
    }

    /// Reconstruye la captura entera. `stop()` destruye el IOProc, el agregado y
    /// el tap, y deja `tapFormat`/`sampleRate` a cero; `start()` crea un tap nuevo
    /// y relee su ASBD. En ningún momento se reutiliza el formato anterior, que es
    /// lo que provocaría un desajuste al cambiar de dispositivo.
    func restart() {
        log("Reconstrucción completa de la captura solicitada.")
        stop()
        if !start() {
            // La app sigue viva con el glow apagado: el error queda en el menú.
            log("La reconstrucción falló. La captura queda detenida y el error visible en el menú.")
        }
    }

    /// Dispositivo elegido en preferencias, o la salida por defecto del sistema.
    private func resolveTargetDevice() -> AudioDeviceID? {
        if let uid = PreferencesManager.shared.inputDeviceUID,
           let match = AudioManager.availableOutputDevices().first(where: { $0.uid == uid }) {
            return match.id
        }
        return AudioManager.defaultOutputDevice()
    }

    // MARK: - Construcción del process tap

    /// Crea un tap global privado: escucha todos los procesos y no aparece
    /// como dispositivo público ni silencia la reproducción.
    private func createTap() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "nLight System Output Tap"
        description.isPrivate = true
        // `.unmuted` es lo que garantiza que el usuario siga oyendo igual.
        description.muteBehavior = .unmuted

        var identifier = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &identifier)

        log("AudioHardwareCreateProcessTap → OSStatus \(status) (\(AudioManager.describe(status))), objectID=\(identifier)")
        guard check(status, "AudioHardwareCreateProcessTap") else {
            diagnostics.tap = "FALLÓ: \(AudioManager.describe(status))"
            return false
        }
        guard identifier != AudioObjectID(kAudioObjectUnknown) else {
            diagnostics.tap = "FALLÓ: objectID inválido pese a OSStatus 0"
            fail("El tap devolvió noErr pero con un objectID inválido.")
            return false
        }

        tapID = identifier
        tapUUID = description.uuid
        diagnostics.tap = "ok · objectID=\(identifier) · uuid=\(description.uuid.uuidString)"
        log("Tap creado: uuid=\(description.uuid.uuidString) privado=\(description.isPrivate) mute=\(description.muteBehavior.rawValue)")
        return true
    }

    /// UUID del tap, necesario para referenciarlo desde el dispositivo agregado.
    private var tapUUID: UUID?

    /// Dispositivo agregado privado que combina la salida real con el tap.
    /// Es el objeto sobre el que se instala el IOProc de captura.
    private func createAggregateDevice(around outputDeviceUID: String) -> Bool {
        guard let tapUUID else {
            fail("El tap no devolvió un UUID válido.")
            return false
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "nLight Capture",
            kAudioAggregateDeviceUIDKey: "com.nlight.app.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            // Privado: no se publica en Ajustes de Sonido ni altera la salida por defecto.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        // Volcado del diccionario ANTES de crear nada: si el agregado sale mal,
        // aquí se ve exactamente con qué sub-device y qué tap se pidió.
        log("""
            Configuración del agregado (antes de crearlo):
              nombre        = nLight Capture
              main/master   = \(outputDeviceUID)
              privado       = true
              stacked       = false
              tapAutoStart  = true
              subDeviceList = [\(outputDeviceUID)]
              tapList       = [\(tapUUID.uuidString)] (driftCompensation=true)
            """)

        var identifier = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &identifier)

        log("AudioHardwareCreateAggregateDevice → OSStatus \(status) (\(AudioManager.describe(status))), deviceID=\(identifier)")
        guard check(status, "AudioHardwareCreateAggregateDevice") else {
            diagnostics.aggregate = "FALLÓ: \(AudioManager.describe(status))"
            return false
        }
        guard identifier != AudioObjectID(kAudioObjectUnknown) else {
            diagnostics.aggregate = "FALLÓ: deviceID inválido pese a OSStatus 0"
            fail("El agregado devolvió noErr pero con un deviceID inválido.")
            return false
        }

        aggregateID = identifier
        diagnostics.aggregate = "ok · deviceID=\(identifier)"
        log("Agregado creado: deviceID=\(identifier), canales de entrada=\(AudioManager.inputChannelCount(of: identifier))")
        return true
    }

    /// Lee el formato que entrega el tap y ajusta la frecuencia de muestreo del análisis.
    private func readTapFormat() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)

        log("kAudioTapPropertyFormat → OSStatus \(status) (\(AudioManager.describe(status)))")
        guard check(status, "Lectura de kAudioTapPropertyFormat") else {
            diagnostics.format = "FALLÓ: \(AudioManager.describe(status))"
            return false
        }

        // Volcado completo del ASBD: es la referencia para saber si el formato
        // que entrega el hardware coincide con el que estamos interpretando.
        log("""
            ASBD del tap:
              mSampleRate       = \(format.mSampleRate)
              mFormatID         = \(AudioManager.fourCharCode(OSStatus(bitPattern: format.mFormatID)))
              mFormatFlags      = 0x\(String(format.mFormatFlags, radix: 16)) \
            (float=\(format.mFormatFlags & kAudioFormatFlagIsFloat != 0), \
            nonInterleaved=\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0), \
            packed=\(format.mFormatFlags & kAudioFormatFlagIsPacked != 0))
              mBytesPerPacket   = \(format.mBytesPerPacket)
              mFramesPerPacket  = \(format.mFramesPerPacket)
              mBytesPerFrame    = \(format.mBytesPerFrame)
              mChannelsPerFrame = \(format.mChannelsPerFrame)
              mBitsPerChannel   = \(format.mBitsPerChannel)
            """)

        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            diagnostics.format = "FALLÓ: formato no flotante"
            fail("El tap entregó un formato no flotante; no soportado.")
            return false
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            diagnostics.format = "FALLÓ: sample rate o canales inválidos"
            fail("El tap entregó un formato inválido (\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) canales).")
            return false
        }

        tapFormat = format
        // La FFT se adapta a ESTE sample rate. Nunca se asume ninguno.
        sampleRate = Float(format.mSampleRate)
        diagnostics.format = "\(Int(format.mSampleRate)) Hz · \(format.mChannelsPerFrame) canales · Float32"
        log("La FFT se adapta a \(Int(format.mSampleRate)) Hz → resolución de \(String(format: "%.2f", format.mSampleRate / Double(AudioManager.fftSize))) Hz por bin.")
        return true
    }

    /// Instala el IOProc sobre el dispositivo agregado y arranca la captura.
    private func startIO() -> Bool {
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            ioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.ingest(inputData)
        }
        log("AudioDeviceCreateIOProcIDWithBlock → OSStatus \(createStatus) (\(AudioManager.describe(createStatus)))")
        guard check(createStatus, "AudioDeviceCreateIOProcIDWithBlock"), let procID else {
            diagnostics.ioProc = "FALLÓ al instalar: \(AudioManager.describe(createStatus))"
            return false
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        log("AudioDeviceStart → OSStatus \(startStatus) (\(AudioManager.describe(startStatus)))")
        guard check(startStatus, "AudioDeviceStart") else {
            diagnostics.ioProc = "FALLÓ al arrancar: \(AudioManager.describe(startStatus))"
            return false
        }

        diagnostics.ioProc = "instalado y arrancado"
        return true
    }

    /// Canales de entrada de un dispositivo: en el agregado son los que aporta el tap.
    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        channelCount(of: device, scope: kAudioObjectPropertyScopeInput)
    }

    /// Desmonta el tap y todo lo construido a su alrededor, en orden inverso.
    private func teardown() {
        if let ioProcID {
            if aggregateID != AudioObjectID(kAudioObjectUnknown) {
                check(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
                check(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
            }
            self.ioProcID = nil
        }

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            check(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            check(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        tapUUID = nil
        tapFormat = nil
    }

    private func reset() {
        stateLock.lock()
        latestSnapshot = AudioSnapshot()
        energyHistory.removeAll(keepingCapacity: true)
        bassPeak = 1e-4
        overallPeak = 1e-4
        ringWriteIndex = 0
        samplesSinceLastFFT = 0
        // El formato muere con la sesión: la siguiente arranca releyendo el ASBD.
        sampleRate = 0
        stateLock.unlock()
    }

    // MARK: - Cambios de dispositivo por defecto

    /// Si el usuario cambia de altavoces a auriculares, hay que rehacer el tap.
    private func observeDefaultOutputDevice() {
        guard defaultDeviceListener == nil,
              PreferencesManager.shared.inputDeviceUID == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                NSLog("[nLight] Cambió la salida por defecto: reconstruyendo el tap.")
                self.restart()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if check(status, "AudioObjectAddPropertyListenerBlock") {
            defaultDeviceListener = listener
        }
    }

    private func stopObservingDefaultOutputDevice() {
        guard let listener = defaultDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        check(AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        ), "AudioObjectRemovePropertyListenerBlock")
        defaultDeviceListener = nil
    }

    // MARK: - Captura

    /// Se ejecuta en la cola de audio: mezcla a mono y alimenta el buffer circular.
    private func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        // Sin un formato recién leído no se procesa nada: tras un cambio de
        // dispositivo, `teardown()` deja esto en nil hasta releer el ASBD nuevo.
        guard let format = tapFormat, sampleRate > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard buffers.count > 0 else { return }

        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var sumOfSquares: Float = 0
        var processedFrames = 0

        if isNonInterleaved {
            let channels = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard !channels.isEmpty else { return }
            let frameCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            let scale = 1 / Float(channels.count)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in channels { sum += channel[frame] }
                let mono = sum * scale
                sumOfSquares += mono * mono
                push(mono)
            }
            processedFrames = frameCount
        } else {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0 else { return }
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channelCount)
            let scale = 1 / Float(channelCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += data[frame * channelCount + channel] }
                let mono = sum * scale
                sumOfSquares += mono * mono
                push(mono)
            }
            processedFrames = frameCount
        }

        let rms = processedFrames > 0 ? sqrt(sumOfSquares / Float(processedFrames)) : 0
        recordCallback(buffers: buffers.count, frames: processedFrames, rms: rms)
    }

    /// Actualiza el diagnóstico del IOProc y lo vuelca a consola con moderación:
    /// las primeras llamadas para confirmar que arranca, y luego cada pocos
    /// segundos para no inundar la Consola.
    private func recordCallback(buffers: Int, frames: Int, rms: Float) {
        diagnosticsLock.lock()
        diagnosticsStorage.callbackCount += 1
        diagnosticsStorage.lastBufferCount = buffers
        diagnosticsStorage.lastFrameCount = frames
        diagnosticsStorage.lastRMS = rms
        let count = diagnosticsStorage.callbackCount
        diagnosticsLock.unlock()

        let shouldLog = count <= 3 || count % 500 == 0
        guard shouldLog else { return }
        log("IOProc #\(count): \(buffers) buffer(s), \(frames) frames, RMS \(String(format: "%.6f", rms))"
            + (rms <= 0.000_01 ? "  ← silencio absoluto: o no suena nada, o el stream no es el correcto" : ""))
    }

    /// Acumula una muestra y lanza la FFT cada medio solapamiento.
    private func push(_ sample: Float) {
        let size = AudioManager.fftSize
        /// Solapamiento del 50 % entre ventanas para una respuesta más fluida.
        let hopSize = size / 2

        sampleRing[ringWriteIndex] = sample
        ringWriteIndex = (ringWriteIndex + 1) % size
        samplesSinceLastFFT += 1

        if samplesSinceLastFFT >= hopSize {
            samplesSinceLastFFT = 0
            analyzeRing()
        }
    }

    /// Ordena el buffer circular, aplica la ventana Hamming y ejecuta la FFT.
    private func analyzeRing() {
        guard let fftSetup else { return }
        let size = AudioManager.fftSize
        let half = size / 2

        // Copia el anillo en orden cronológico dentro de `windowed`.
        let tailCount = size - ringWriteIndex
        windowed.withUnsafeMutableBufferPointer { dst in
            sampleRing.withUnsafeBufferPointer { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                let elementSize = MemoryLayout<Float>.stride
                memcpy(dstBase, srcBase + ringWriteIndex, tailCount * elementSize)
                if ringWriteIndex > 0 {
                    memcpy(dstBase + tailCount, srcBase, ringWriteIndex * elementSize)
                }
            }
        }

        windowed.withUnsafeMutableBufferPointer { signal in
            window.withUnsafeBufferPointer { taper in
                vDSP_vmul(signal.baseAddress!, 1, taper.baseAddress!, 1,
                          signal.baseAddress!, 1, vDSP_Length(size))
            }
        }

        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
                    // vDSP_fft_zrip devuelve el resultado escalado por 2: se normaliza por el tamaño.
                    var scale = Float(1.0) / Float(size)
                    vDSP_vsmul(output.baseAddress!, 1, &scale, output.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        updateLevels()
    }

    /// Convierte el espectro en niveles normalizados y decide si hubo beat.
    private func updateLevels() {
        let half = AudioManager.fftSize / 2
        // Sin formato válido no hay análisis posible: `Int(x / 0)` sería infinito
        // y convertirlo a entero abortaría el proceso.
        guard sampleRate > 0 else { return }
        let binWidth = sampleRate / Float(AudioManager.fftSize)
        // El bin 0 es DC: se descarta para no falsear la energía de graves.
        let firstBassBin = 1
        let lastBassBin = max(firstBassBin, min(half - 1, Int(AudioManager.bassUpperHz / binWidth)))

        var bassEnergy: Float = 0
        magnitudes.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            let count = vDSP_Length(lastBassBin - firstBassBin + 1)
            vDSP_svesq(base + firstBassBin, 1, &bassEnergy, count)
        }
        var overallEnergy: Float = 0
        vDSP_svesq(magnitudes, 1, &overallEnergy, vDSP_Length(half))

        let bassMagnitude = sqrt(bassEnergy)
        let overallMagnitude = sqrt(overallEnergy)

        stateLock.lock()

        // Normalización adaptativa: el pico decae lentamente para acompañar
        // cambios de volumen sin saturar ni apagarse.
        bassPeak = max(bassMagnitude, bassPeak * 0.9985)
        overallPeak = max(overallMagnitude, overallPeak * 0.9985)
        bassPeak = max(bassPeak, 1e-4)
        overallPeak = max(overallPeak, 1e-4)

        let noiseFloor: Float = 2e-4
        var bassLevel = bassMagnitude > noiseFloor ? bassMagnitude / bassPeak : 0
        var overallLevel = overallMagnitude > noiseFloor ? overallMagnitude / overallPeak : 0
        bassLevel = min(max(bassLevel, 0), 1)
        overallLevel = min(max(overallLevel, 0), 1)

        // Detección de beat: energía instantánea contra la media móvil reciente.
        energyHistory.append(bassEnergy)
        if energyHistory.count > AudioManager.energyHistoryLength {
            energyHistory.removeFirst(energyHistory.count - AudioManager.energyHistoryLength)
        }

        if energyHistory.count == AudioManager.energyHistoryLength, bassMagnitude > noiseFloor {
            let average = energyHistory.reduce(0, +) / Float(energyHistory.count)
            let threshold = average * beatSensitivity
            let now = CACurrentMediaTime()
            if bassEnergy > threshold, now - lastBeatTime > AudioManager.beatCooldown {
                lastBeatTime = now
            }
        }

        latestSnapshot.bassLevel = bassLevel
        latestSnapshot.overallLevel = overallLevel
        stateLock.unlock()
    }

    // MARK: - Errores de CoreAudio

    /// Registra el fallo en consola y lo guarda para mostrarlo en el menú.
    @discardableResult
    private func check(_ status: OSStatus, _ operation: String) -> Bool {
        guard status != noErr else { return true }
        let detail = "\(operation) falló: \(AudioManager.describe(status))"
        NSLog("[nLight] %@", detail)
        lastErrorDescription = detail
        return false
    }

    private func fail(_ message: String) {
        NSLog("[nLight] %@", message)
        lastErrorDescription = message
    }

    /// Traduce los OSStatus de CoreAudio a algo legible, con su código FourCC.
    private static func describe(_ status: OSStatus) -> String {
        let known: [OSStatus: String] = [
            kAudioHardwareNotRunningError: "el servidor de audio no está en marcha",
            kAudioHardwareUnspecifiedError: "error no especificado del hardware de audio",
            kAudioHardwareUnknownPropertyError: "propiedad desconocida",
            kAudioHardwareBadPropertySizeError: "tamaño de propiedad incorrecto",
            kAudioHardwareIllegalOperationError: "operación no permitida",
            kAudioHardwareBadObjectError: "objeto de audio inválido",
            kAudioHardwareBadDeviceError: "dispositivo de audio inválido",
            kAudioHardwareBadStreamError: "stream de audio inválido",
            kAudioHardwareUnsupportedOperationError: "operación no soportada",
            kAudioDeviceUnsupportedFormatError: "formato no soportado por el dispositivo",
            kAudioDevicePermissionsError: "permiso denegado: concede la captura de audio en Ajustes → Privacidad y seguridad"
        ]

        let reason = known[status] ?? "consulta la documentación de CoreAudio"
        return "\(reason) [\(fourCharCode(status)) / OSStatus \(status)]"
    }

    /// Los errores de CoreAudio suelen ser códigos de cuatro caracteres ('!obj', 'stop'…).
    private static func fourCharCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "sin código" }
        return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
    }

    // MARK: - Dispositivos de salida (CoreAudio)

    /// Salida por defecto del sistema: lo que el usuario está oyendo ahora mismo.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// Lista los dispositivos del sistema que tienen al menos un canal de salida.
    static func availableOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard outputChannelCount(of: id) > 0,
                  let name = stringProperty(kAudioObjectPropertyName, of: id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func outputChannelCount(of device: AudioDeviceID) -> Int {
        channelCount(of: device, scope: kAudioObjectPropertyScopeOutput)
    }

    /// Cuenta canales en un scope concreto.
    ///
    /// Ojo al leer esto: el único uso del scope de ENTRADA es contar los canales
    /// que el *tap* aporta al dispositivo agregado, como dato de diagnóstico.
    /// No hay ninguna captura asociada, y jamás se consulta sobre un micrófono.
    private static func channelCount(of device: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, buffer) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
