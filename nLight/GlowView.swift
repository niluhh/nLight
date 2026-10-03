//
//  GlowView.swift
//  nLight
//
//  Dibuja el brillo de los cuatro bordes con degradados NSGradient.
//  Los bordes superior/inferior y los laterales usan colores independientes.
//

import AppKit

final class GlowView: NSView {

    /// Nivel de graves suavizado (0...1). Controla grosor y opacidad.
    var level: CGFloat = 0 {
        didSet { if abs(level - oldValue) > 0.001 { needsDisplay = true } }
    }

    /// Destello adicional (0...1) que decae tras cada beat detectado.
    var beatFlash: CGFloat = 0 {
        didSet { if abs(beatFlash - oldValue) > 0.001 { needsDisplay = true } }
    }

    /// Colores que sustituyen a los de preferencias mientras el seguimiento de
    /// Spotify está activo. A `nil`, mandan los colores manuales guardados.
    var paletteOverride: GlowPalette? {
        didSet { if paletteOverride != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    /// El overlay nunca debe capturar clics.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let preferences = PreferencesManager.shared
        let intensity = CGFloat(preferences.intensity)
        let response = min(max(level * intensity, 0), 1.5)
        guard response > 0.015 else { return }

        let flash = min(max(beatFlash, 0), 1)
        let baseThickness = CGFloat(preferences.thickness)
        let thickness = baseThickness * min(0.25 + 0.75 * response + 0.15 * flash, 1.35)
        let alpha = min(0.06 + 0.94 * response + 0.12 * flash, 1)

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        // Los bordes se solapan en las esquinas: sumar la luz evita bandas oscuras.
        context.compositingOperation = .plusLighter

        let bounds = self.bounds
        let horizontal = paletteOverride?.horizontal ?? preferences.horizontalColor
        let vertical = paletteOverride?.vertical ?? preferences.verticalColor

        // Superior: opaco arriba, desvanecido hacia abajo.
        draw(gradientFor: horizontal, alpha: alpha,
             in: NSRect(x: bounds.minX, y: bounds.maxY - thickness,
                        width: bounds.width, height: thickness),
             angle: 270)

        // Inferior.
        draw(gradientFor: horizontal, alpha: alpha,
             in: NSRect(x: bounds.minX, y: bounds.minY,
                        width: bounds.width, height: thickness),
             angle: 90)

        // Izquierdo.
        draw(gradientFor: vertical, alpha: alpha,
             in: NSRect(x: bounds.minX, y: bounds.minY,
                        width: thickness, height: bounds.height),
             angle: 0)

        // Derecho.
        draw(gradientFor: vertical, alpha: alpha,
             in: NSRect(x: bounds.maxX - thickness, y: bounds.minY,
                        width: thickness, height: bounds.height),
             angle: 180)

        context.restoreGraphicsState()
    }

    /// Degradado de tres paradas: núcleo intenso, caída rápida y desvanecido total.
    private func draw(gradientFor color: NSColor, alpha: CGFloat, in rect: NSRect, angle: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        let base = color.usingColorSpace(.sRGB) ?? color
        let gradient = NSGradient(colorsAndLocations:
            (base.withAlphaComponent(alpha), 0.0),
            (base.withAlphaComponent(alpha * 0.45), 0.35),
            (base.withAlphaComponent(alpha * 0.12), 0.7),
            (base.withAlphaComponent(0.0), 1.0)
        )
        gradient?.draw(in: rect, angle: angle)
    }
}
