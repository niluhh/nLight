//
//  AppDelegate.swift
//  nLight
//
//  Punto de entrada de la aplicación: crea el icono de la barra de menús,
//  construye el menú de control y coordina audio y renderizado.
//

import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let preferences = PreferencesManager.shared
    private let audioManager = AudioManager()
    private let glowController = GlowController()

    private var statusItem: NSStatusItem!
    private var diagnosticsItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var statusInfoItem: NSMenuItem!
    private var intensityControl: SliderMenuView!
    private var thicknessControl: SliderMenuView!
    private var sensitivityControl: SliderMenuView!
    private var horizontalColorItem: NSMenuItem!
    private var verticalColorItem: NSMenuItem!
    private var deviceMenu: NSMenu!

    private var editingColorSlot: GlowEdgePair = .horizontal

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        glowController.snapshotProvider = { [weak self] in
            self?.audioManager.snapshot ?? AudioSnapshot()
        }

        buildStatusItem()
        refreshMenuState()

        if preferences.isEnabled {
            enableGlow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        glowController.stop()
        audioManager.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Barra de menús

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💡"
        statusItem.button?.toolTip = "nLight"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusInfoItem = NSMenuItem(title: "nLight", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

        // Estado detallado de la cadena de captura. Se mantiene siempre visible
        // para que un fallo del tap sea evidente en vez de silencioso.
        diagnosticsItem = NSMenuItem(title: "Diagnóstico",
                                     action: #selector(copyDiagnostics),
                                     keyEquivalent: "")
        diagnosticsItem.target = self
        diagnosticsItem.toolTip = "Haz clic para copiar el diagnóstico completo al portapapeles"
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Activar brillo",
                                action: #selector(toggleEnabled),
                                keyEquivalent: "l")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        intensityControl = SliderMenuView(
            title: "Intensidad",
            range: PreferencesManager.Limits.intensity,
            value: preferences.intensity,
            format: { String(format: "%.2f×", $0) }
        ) { [weak self] value in
            self?.preferences.intensity = value
        }
        menu.addItem(menuItem(hosting: intensityControl))

        thicknessControl = SliderMenuView(
            title: "Grosor",
            range: PreferencesManager.Limits.thickness,
            value: preferences.thickness,
            format: { String(format: "%.0f px", $0) }
        ) { [weak self] value in
            self?.preferences.thickness = value
        }
        menu.addItem(menuItem(hosting: thicknessControl))

        sensitivityControl = SliderMenuView(
            title: "Sensibilidad al beat",
            range: PreferencesManager.Limits.sensitivity,
            value: preferences.sensitivity,
            format: { String(format: "%.2f", $0) }
        ) { [weak self] value in
            self?.preferences.sensitivity = value
        }
        menu.addItem(menuItem(hosting: sensitivityControl))

        menu.addItem(.separator())

        horizontalColorItem = NSMenuItem(title: "Color superior / inferior", action: nil, keyEquivalent: "")
        horizontalColorItem.submenu = colorSubmenu(for: .horizontal)
        menu.addItem(horizontalColorItem)

        verticalColorItem = NSMenuItem(title: "Color izquierda / derecha", action: nil, keyEquivalent: "")
        verticalColorItem.submenu = colorSubmenu(for: .vertical)
        menu.addItem(verticalColorItem)

        menu.addItem(.separator())

        let deviceItem = NSMenuItem(title: "Fuente de audio", action: nil, keyEquivalent: "")
        deviceMenu = NSMenu()
        deviceMenu.autoenablesItems = false
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        menu.addItem(.separator())

        let resetItem = NSMenuItem(title: "Restablecer valores",
                                   action: #selector(resetPreferences),
                                   keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let aboutItem = NSMenuItem(title: "Acerca de nLight",
                                   action: #selector(showAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Salir de nLight",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func menuItem(hosting view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func colorSubmenu(for slot: GlowEdgePair) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for preset in ColorPreset.all {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(selectPresetColor(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = ColorPreset.swatch(for: preset.color)
            item.representedObject = ColorSelection(slot: slot, color: preset.color)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let custom = NSMenuItem(title: "Personalizado…",
                                action: #selector(openColorPanel(_:)),
                                keyEquivalent: "")
        custom.target = self
        custom.representedObject = ColorSelection(slot: slot, color: nil)
        submenu.addItem(custom)

        return submenu
    }

    // MARK: - Estado del menú

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
        rebuildDeviceMenu()
    }

    /// Vuelca el estado completo de la cadena de captura al portapapeles, para
    /// poder pegarlo en un issue sin tener que rebuscar en Consola.
    @objc private func copyDiagnostics() {
        let diagnostics = audioManager.diagnostics
        let report = """
        nLight — diagnóstico de captura
        Captura: process tap de CoreAudio (el proyecto no contiene ninguna ruta de micrófono)

        Permiso de captura de audio : \(diagnostics.authorization)
        Dispositivo objetivo        : \(diagnostics.targetDevice)
        Tap                         : \(diagnostics.tap)
        Formato (ASBD del tap)      : \(diagnostics.format)
        Dispositivo agregado        : \(diagnostics.aggregate)
        IOProc                      : \(diagnostics.ioProc)
        Llamadas al IOProc          : \(diagnostics.callbackCount)
        Último bloque               : \(diagnostics.lastBufferCount) buffer(s), \(diagnostics.lastFrameCount) frames
        RMS del último bloque       : \(diagnostics.lastRMS)
        Motor en marcha             : \(audioManager.isRunning)
        Último error                : \(audioManager.lastErrorDescription ?? "ninguno")

        Detalle completo en Consola.app filtrando por [nLight].
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        NSLog("[nLight] Diagnóstico copiado al portapapeles:\n%@", report)
    }

    private func refreshMenuState() {
        let enabled = preferences.isEnabled
        toggleItem.title = enabled ? "Desactivar brillo" : "Activar brillo"
        toggleItem.state = enabled ? .on : .off
        statusItem.button?.alphaValue = enabled ? 1.0 : 0.45

        if let error = audioManager.lastErrorDescription, enabled {
            statusInfoItem.title = "⚠️ \(error)"
        } else if enabled {
            statusInfoItem.title = audioManager.isRunning ? "Escuchando audio" : "Sin captura de audio"
        } else {
            statusInfoItem.title = "nLight en pausa"
        }

        let diagnostics = audioManager.diagnostics
        if enabled {
            diagnosticsItem.title = audioManager.isRunning
                ? "Diagnóstico: \(diagnostics.summary)"
                : "Diagnóstico: captura detenida — \(diagnostics.tap)"
        } else {
            diagnosticsItem.title = "Diagnóstico: nLight en pausa"
        }

        intensityControl?.value = preferences.intensity
        thicknessControl?.value = preferences.thickness
        sensitivityControl?.value = preferences.sensitivity
        horizontalColorItem?.image = ColorPreset.swatch(for: preferences.horizontalColor)
        verticalColorItem?.image = ColorPreset.swatch(for: preferences.verticalColor)
    }

    private func rebuildDeviceMenu() {
        deviceMenu.removeAllItems()

        let systemDefault = NSMenuItem(title: "Salida por defecto del sistema",
                                       action: #selector(selectInputDevice(_:)),
                                       keyEquivalent: "")
        systemDefault.target = self
        systemDefault.state = preferences.inputDeviceUID == nil ? .on : .off
        deviceMenu.addItem(systemDefault)

        let devices = AudioManager.availableOutputDevices()
        if !devices.isEmpty { deviceMenu.addItem(.separator()) }

        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(selectInputDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = preferences.inputDeviceUID == device.uid ? .on : .off
            deviceMenu.addItem(item)
        }

        deviceMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Captura el audio del sistema, nunca el micrófono",
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        deviceMenu.addItem(hint)
    }

    // MARK: - Acciones

    @objc private func toggleEnabled() {
        preferences.isEnabled.toggle()
        if preferences.isEnabled {
            enableGlow()
        } else {
            glowController.stop()
            audioManager.stop()
        }
        refreshMenuState()
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ColorSelection,
              let color = selection.color else { return }
        apply(color: color, to: selection.slot)
        refreshMenuState()
    }

    @objc private func openColorPanel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ColorSelection else { return }
        editingColorSlot = selection.slot

        let panel = NSColorPanel.shared
        panel.isContinuous = true
        panel.color = selection.slot == .horizontal ? preferences.horizontalColor : preferences.verticalColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        apply(color: sender.color, to: editingColorSlot)
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        preferences.inputDeviceUID = sender.representedObject as? String
        if preferences.isEnabled {
            audioManager.restart()
        }
        refreshMenuState()
    }

    @objc private func resetPreferences() {
        preferences.resetToDefaults()
        if preferences.isEnabled {
            audioManager.restart()
            glowController.start()
        } else {
            glowController.stop()
            audioManager.stop()
        }
        refreshMenuState()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "nLight"
        alert.informativeText = """
        Brillo reactivo al audio en los bordes de la pantalla.

        Analiza el audio que sale del sistema con una FFT de \(AudioManager.fftSize) \
        muestras y detecta los beats en la banda de 0 a \(Int(AudioManager.bassUpperHz)) Hz.

        Usa un process tap de CoreAudio: captura lo que suena en Spotify, Music o el \
        navegador sin tocar el micrófono y sin instalar drivers de terceros.

        Proyecto de código abierto bajo licencia MIT.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cerrar")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Coordinación

    private func apply(color: NSColor, to slot: GlowEdgePair) {
        switch slot {
        case .horizontal: preferences.horizontalColor = color
        case .vertical: preferences.verticalColor = color
        }
    }

    private func enableGlow() {
        audioManager.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.preferences.isEnabled = false
                self.refreshMenuState()
                self.presentPermissionAlert()
                return
            }
            if !self.audioManager.start() {
                self.presentAudioErrorAlert()
            }
            self.glowController.start()
            self.refreshMenuState()
        }
    }

    private func presentPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "nLight necesita acceso al audio"
        alert.informativeText = """
        macOS protege la captura del audio del sistema con un permiso. Concédelo en \
        Ajustes del Sistema → Privacidad y seguridad y vuelve a activar el brillo \
        desde el menú.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentAudioErrorAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No se pudo iniciar la captura de audio"
        alert.informativeText = audioManager.lastErrorDescription
            ?? "Comprueba el dispositivo seleccionado en «Fuente de audio»."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cerrar")
        alert.runModal()
    }
}

// MARK: - Tipos auxiliares del menú

/// Par de bordes al que se aplica un color.
enum GlowEdgePair {
    /// Bordes superior e inferior.
    case horizontal
    /// Bordes izquierdo y derecho.
    case vertical
}

/// Color asociado a un elemento del menú (`nil` abre el selector del sistema).
private final class ColorSelection: NSObject {
    let slot: GlowEdgePair
    let color: NSColor?

    init(slot: GlowEdgePair, color: NSColor?) {
        self.slot = slot
        self.color = color
    }
}

enum ColorPreset {
    static let all: [(name: String, color: NSColor)] = [
        ("Rojo", .systemRed),
        ("Naranja", .systemOrange),
        ("Amarillo", .systemYellow),
        ("Verde", .systemGreen),
        ("Turquesa", .systemTeal),
        ("Azul", .systemBlue),
        ("Índigo", .systemIndigo),
        ("Morado", .systemPurple),
        ("Rosa", .systemPink),
        ("Blanco", .white)
    ]

    /// Cuadrado de color usado como icono en los elementos del menú.
    static func swatch(for color: NSColor, size: NSSize = NSSize(width: 14, height: 14)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}

/// Vista con etiqueta, valor y deslizador para incrustar en un `NSMenuItem`.
final class SliderMenuView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            valueLabel.stringValue = format(newValue)
        }
    }

    init(title: String,
         range: ClosedRange<Double>,
         value: Double,
         format: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 54))

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.textColor = .labelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        valueLabel.stringValue = format(value)

        let controls: [NSView] = [titleLabel, valueLabel, slider]
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SliderMenuView no admite inicialización desde un archivo nib")
    }

    @objc private func sliderChanged() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}
