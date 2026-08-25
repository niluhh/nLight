//
//  AudioManager.swift
//  nLight
//
//  Captura de audio en tiempo real, FFT con Accelerate y detección de beats
//  en el rango de bajas frecuencias (0 - 250 Hz).
//

import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import QuartzCore

/// Descripción de un dispositivo de entrada de CoreAudio.
struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
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

    /// Instantánea más reciente. Segura de leer desde el hilo principal.
    var snapshot: AudioSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        var current = latestSnapshot
        current.beat = CACurrentMediaTime() - lastBeatTime < AudioManager.beatHoldTime
        return current
    }

    // MARK: - Privados

    private let engine = AVAudioEngine()
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
    private var sampleRate: Float = 44100
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
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
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

    /// Pide permiso de micrófono (necesario también para dispositivos virtuales de loopback).
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

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        applyPreferredInputDevice()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastErrorDescription = "El dispositivo de entrada no expone un formato válido."
            return false
        }
        sampleRate = Float(format.sampleRate)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            lastErrorDescription = nil
            return true
        } catch {
            input.removeTap(onBus: 0)
            lastErrorDescription = error.localizedDescription
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        reset()
    }

    func restart() {
        stop()
        _ = start()
    }

    private func reset() {
        stateLock.lock()
        latestSnapshot = AudioSnapshot()
        energyHistory.removeAll(keepingCapacity: true)
        bassPeak = 1e-4
        overallPeak = 1e-4
        ringWriteIndex = 0
        samplesSinceLastFFT = 0
        stateLock.unlock()
    }

    @objc private func handleConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.restart()
        }
    }

    // MARK: - Captura

    /// Se ejecuta en el hilo de audio en tiempo real: sin asignaciones ni locks largos.
    private func process(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let size = AudioManager.fftSize
        /// Solapamiento del 50 % entre ventanas para una respuesta más fluida.
        let hopSize = size / 2

        for index in 0..<frameCount {
            sampleRing[ringWriteIndex] = channel[index]
            ringWriteIndex = (ringWriteIndex + 1) % size
            samplesSinceLastFFT += 1

            if samplesSinceLastFFT >= hopSize {
                samplesSinceLastFFT = 0
                analyzeRing()
            }
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

    // MARK: - Dispositivos de entrada (CoreAudio)

    /// Aplica el dispositivo guardado en preferencias a la unidad de entrada del engine.
    private func applyPreferredInputDevice() {
        guard let uid = PreferencesManager.shared.inputDeviceUID,
              let device = AudioManager.availableInputDevices().first(where: { $0.uid == uid }),
              let unit = engine.inputNode.audioUnit else { return }

        var deviceID = device.id
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &deviceID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Lista los dispositivos del sistema que tienen al menos un canal de entrada.
    static func availableInputDevices() -> [AudioInputDevice] {
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
            guard inputChannelCount(of: id) > 0,
                  let name = stringProperty(kAudioObjectPropertyName, of: id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
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
