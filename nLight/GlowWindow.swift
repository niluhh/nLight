//
//  GlowWindow.swift
//  nLight
//
//  Ventana transparente, sin bordes y no interactiva que cubre una pantalla
//  completa para servir de lienzo al brillo.
//

import AppKit

final class GlowWindow: NSWindow {

    let glowView = GlowView(frame: .zero)
    private(set) var screenID: CGDirectDisplayID = 0

    convenience init(screen: NSScreen) {
        self.init(contentRect: screen.frame,
                  styleMask: [.borderless],
                  backing: .buffered,
                  defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // Por encima de las ventanas normales, sin robar el foco.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // El overlay no debería aparecer en capturas de pantalla ni grabaciones.
        sharingType = .none

        glowView.autoresizingMask = [.width, .height]
        contentView = glowView
        update(for: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Reubica la ventana cuando cambia la geometría de las pantallas.
    func update(for screen: NSScreen) {
        screenID = GlowWindow.displayID(of: screen)
        setFrame(screen.frame, display: true)
        glowView.frame = NSRect(origin: .zero, size: screen.frame.size)
        glowView.needsDisplay = true
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}

/// Mantiene una `GlowWindow` por pantalla y las sincroniza con el nivel de
/// audio, aplicando el suavizado de la animación.
@MainActor
final class GlowController: NSObject {

    private var windows: [GlowWindow] = []
    private var displayTimer: Timer?
    private var smoothedLevel: CGFloat = 0
    private var beatFlash: CGFloat = 0
    private var isVisible = false

    /// Fuente del nivel de audio: devuelve el análisis más reciente.
    var snapshotProvider: (() -> AudioSnapshot)?

    /// Paleta derivada de Spotify, o `nil` para usar los colores de preferencias.
    var paletteProvider: (() -> GlowPalette?)?

    override init() {
        super.init()
        rebuildWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: PreferencesManager.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayTimer?.invalidate()
    }

    func start() {
        isVisible = true
        windows.forEach { $0.show() }
        guard displayTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` mantiene viva la animación mientras el menú está abierto.
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        isVisible = false
        smoothedLevel = 0
        beatFlash = 0
        windows.forEach {
            $0.glowView.level = 0
            $0.glowView.beatFlash = 0
            $0.hide()
        }
    }

    private func tick() {
        let snapshot = snapshotProvider?() ?? AudioSnapshot()
        let smoothing = PreferencesManager.shared.smoothingFactor
        let target = CGFloat(snapshot.bassLevel)

        smoothedLevel += (target - smoothedLevel) * smoothing
        beatFlash = snapshot.beat ? 1 : beatFlash * 0.82

        let palette = paletteProvider?()

        for window in windows {
            window.glowView.level = smoothedLevel
            window.glowView.beatFlash = beatFlash
            window.glowView.paletteOverride = palette
        }
    }

    @objc private func screensChanged() {
        rebuildWindows()
        if isVisible { windows.forEach { $0.show() } }
    }

    @objc private func preferencesChanged() {
        windows.forEach { $0.glowView.needsDisplay = true }
    }

    private func rebuildWindows() {
        var reused: [GlowWindow] = []

        for screen in NSScreen.screens {
            let id = GlowWindow.displayID(of: screen)
            if let existing = windows.first(where: { $0.screenID == id }) {
                existing.update(for: screen)
                reused.append(existing)
            } else {
                reused.append(GlowWindow(screen: screen))
            }
        }

        for obsolete in windows where !reused.contains(where: { $0 === obsolete }) {
            obsolete.hide()
        }
        windows = reused
    }
}
