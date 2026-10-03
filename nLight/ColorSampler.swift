//
//  ColorSampler.swift
//  nLight
//
//  Lee el color dominante de la ventana de Spotify y deriva de él una pareja
//  de colores armónicos para los bordes del glow.
//
//  Spotify calcula el fondo del modo letra a partir de la portada del disco,
//  así que muestrear los píxeles reales de su ventana es la forma más fiel de
//  seguir ese color: no hace falta API, ni red, ni credenciales.
//
//  Captura solo la ventana de Spotify, reducida a una miniatura, una vez por
//  segundo. Requiere permiso de Grabación de pantalla.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Pareja de colores derivada de la portada actual.
struct GlowPalette: Equatable {
    /// Bordes superior e inferior.
    let horizontal: NSColor
    /// Bordes izquierdo y derecho.
    let vertical: NSColor
}

@MainActor
final class ColorSampler {

    /// Bundle de Spotify. El muestreo se limita a sus ventanas.
    private static let spotifyBundleID = "com.spotify.client"

    /// Lado de la miniatura capturada. Suficiente para un color dominante y
    /// ridículamente barato de procesar.
    private static let thumbnailSide = 64

    /// Cada cuánto se vuelve a mirar la ventana.
    private static let sampleInterval: Duration = .seconds(1)

    /// Cuánto se acerca la paleta a su objetivo en cada muestra (0...1).
    /// Bajo a propósito: el cambio de canción debe fundirse, no saltar.
    private static let blendFactor: CGFloat = 0.12

    /// Paleta vigente, ya suavizada. `nil` mientras no haya un color fiable,
    /// y entonces el glow usa los colores manuales de preferencias.
    private(set) var palette: GlowPalette?

    /// Texto de estado para el menú de diagnóstico.
    private(set) var status = "inactivo"

    private var task: Task<Void, Never>?
    private var smoothedHue: CGFloat?
    private var smoothedSaturation: CGFloat = 0
    private var smoothedBrightness: CGFloat = 0

    var isRunning: Bool { task != nil }

    // MARK: - Ciclo de vida

    func start() {
        guard task == nil else { return }

        guard CGPreflightScreenCaptureAccess() else {
            // Dispara la solicitud del sistema; el usuario debe reiniciar la app
            // después de concederlo, que es como macOS trata este permiso.
            let granted = CGRequestScreenCaptureAccess()
            status = granted
                ? "permiso recién concedido: reinicia nLight"
                : "permiso de grabación de pantalla denegado"
            log("Grabación de pantalla no autorizada. \(status)")
            return
        }

        status = "buscando la ventana de Spotify"
        log("Seguimiento de color de Spotify activado.")

        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                try? await Task.sleep(for: ColorSampler.sampleInterval)
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        palette = nil
        smoothedHue = nil
        status = "inactivo"
        log("Seguimiento de color de Spotify detenido.")
    }

    // MARK: - Muestreo

    private func sampleOnce() async {
        guard let window = await spotifyWindow() else {
            status = "Spotify no está abierto o su ventana no es visible"
            return
        }

        guard let image = await captureThumbnail(of: window) else {
            status = "no se pudo capturar la ventana de Spotify"
            return
        }

        guard let dominant = ColorSampler.dominantColor(in: image) else {
            status = "la ventana no tiene ningún color dominante claro"
            return
        }

        apply(dominant)
    }

    /// Ventana principal de Spotify: la de mayor área, para descartar paneles
    /// auxiliares y la mini-ventana de reproducción.
    private func spotifyWindow() async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return content.windows
                .filter { $0.owningApplication?.bundleIdentifier == ColorSampler.spotifyBundleID }
                .filter { $0.frame.width > 200 && $0.frame.height > 200 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        } catch {
            status = "error al listar ventanas: \(error.localizedDescription)"
            log("SCShareableContent falló: \(error.localizedDescription)")
            return nil
        }
    }

    private func captureThumbnail(of window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = ColorSampler.thumbnailSide
        configuration.height = ColorSampler.thumbnailSide
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // Escalar al vuelo evita mover el framebuffer entero por cada muestra.
        configuration.scalesToFit = true

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            log("Captura de la ventana de Spotify falló: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Extracción del color dominante

    /// Devuelve el tono dominante de la imagen junto con su saturación y brillo
    /// medios, en forma de componentes HSB.
    ///
    /// Trabaja por histograma de tonos en vez de por media aritmética: promediar
    /// los píxeles de una portada da siempre un gris parduzco, mientras que el
    /// tono más repetido es justo el que Spotify usa de fondo.
    private static func dominantColor(in image: CGImage) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 36 cubetas de 10° cada una.
        let bucketCount = 36
        var weights = [CGFloat](repeating: 0, count: bucketCount)
        var saturationSums = [CGFloat](repeating: 0, count: bucketCount)
        var brightnessSums = [CGFloat](repeating: 0, count: bucketCount)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[index]) / 255
            let green = CGFloat(pixels[index + 1]) / 255
            let blue = CGFloat(pixels[index + 2]) / 255

            let (hue, saturation, brightness) = rgbToHSB(red: red, green: green, blue: blue)

            // El cromo gris de Spotify y el texto blanco no deben votar.
            guard saturation > 0.18, brightness > 0.12, brightness < 0.97 else { continue }

            let bucket = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
            // Los píxeles más saturados pesan más: son los del fondo de color.
            let weight = saturation * saturation
            weights[bucket] += weight
            saturationSums[bucket] += saturation * weight
            brightnessSums[bucket] += brightness * weight
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > 0 else { return nil }

        let totalWeight = weights[best]
        let hue = (CGFloat(best) + 0.5) / CGFloat(bucketCount)
        return (hue,
                saturationSums[best] / totalWeight,
                brightnessSums[best] / totalWeight)
    }

    private static func rgbToHSB(red: CGFloat, green: CGFloat, blue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        var hue: CGFloat = 0
        if delta > 0 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        let saturation = maximum == 0 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }

    // MARK: - Derivación de la paleta

    /// Mezcla el color recién medido con el vigente y construye la pareja final.
    private func apply(_ measured: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)) {
        let blend = ColorSampler.blendFactor

        if let current = smoothedHue {
            // El tono es circular: interpolar por el arco corto evita que un paso
            // de rojo (0.98) a naranja (0.03) recorra toda la rueda al revés.
            var difference = measured.hue - current
            if difference > 0.5 { difference -= 1 }
            if difference < -0.5 { difference += 1 }
            var updated = current + difference * blend
            if updated < 0 { updated += 1 }
            if updated >= 1 { updated -= 1 }
            smoothedHue = updated
            smoothedSaturation += (measured.saturation - smoothedSaturation) * blend
            smoothedBrightness += (measured.brightness - smoothedBrightness) * blend
        } else {
            smoothedHue = measured.hue
            smoothedSaturation = measured.saturation
            smoothedBrightness = measured.brightness
        }

        guard let hue = smoothedHue else { return }

        // Un glow apagado no se ve: se eleva saturación y brillo a un mínimo
        // sin perder el tono, que es lo que de verdad coordina con la pantalla.
        let saturation = min(max(smoothedSaturation, 0.55), 0.95)
        let brightness = min(max(smoothedBrightness, 0.80), 1.0)

        // Los laterales usan un tono análogo (+32°): armoniza con el principal
        // en vez de competir con él, que es justo lo que se busca.
        let analogousHue = (hue + 32.0 / 360.0).truncatingRemainder(dividingBy: 1)

        palette = GlowPalette(
            horizontal: NSColor(hue: hue, saturation: saturation,
                                brightness: brightness, alpha: 1),
            vertical: NSColor(hue: analogousHue, saturation: saturation * 0.92,
                              brightness: brightness, alpha: 1)
        )

        status = String(format: "siguiendo a Spotify · tono %.0f°", hue * 360)
    }

    private func log(_ message: String) {
        NSLog("[nLight] %@", message)
    }
}
