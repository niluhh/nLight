//
//  PreferencesManager.swift
//  nLight
//
//  Wrapper sobre UserDefaults con valores por defecto y validación de rangos.
//

import AppKit

final class PreferencesManager {

    static let shared = PreferencesManager()

    /// Se emite cada vez que cambia una preferencia.
    static let didChangeNotification = Notification.Name("nLight.preferencesDidChange")

    enum Key {
        static let enabled = "nLight.enabled"
        static let intensity = "nLight.intensity"
        static let thickness = "nLight.thickness"
        static let horizontalColor = "nLight.horizontalColor"
        static let verticalColor = "nLight.verticalColor"
        static let sensitivity = "nLight.sensitivity"
        static let inputDeviceUID = "nLight.inputDeviceUID"
    }

    enum Limits {
        static let intensity: ClosedRange<Double> = 0.1...2.0
        static let thickness: ClosedRange<Double> = 10.0...80.0
        static let sensitivity: ClosedRange<Double> = 1.05...2.5
    }

    enum Defaults {
        static let enabled = true
        static let intensity = 1.0
        static let thickness = 40.0
        static let sensitivity = 1.35
        /// Bordes superior e inferior.
        static let horizontalColor = NSColor.systemRed
        /// Bordes izquierdo y derecho.
        static let verticalColor = NSColor.systemBlue
    }

    /// Factor de suavizado de la animación (0 = congelado, 1 = sin suavizar).
    let smoothingFactor: CGFloat = 0.15

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: Defaults.enabled,
            Key.intensity: Defaults.intensity,
            Key.thickness: Defaults.thickness,
            Key.sensitivity: Defaults.sensitivity
        ])
    }

    // MARK: - Propiedades

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { set(newValue, forKey: Key.enabled) }
    }

    var intensity: Double {
        get { defaults.double(forKey: Key.intensity).clamped(to: Limits.intensity) }
        set { set(newValue.clamped(to: Limits.intensity), forKey: Key.intensity) }
    }

    var thickness: Double {
        get { defaults.double(forKey: Key.thickness).clamped(to: Limits.thickness) }
        set { set(newValue.clamped(to: Limits.thickness), forKey: Key.thickness) }
    }

    /// Umbral de detección de beats: cuánto debe superar la energía instantánea
    /// a la media reciente para contar como golpe.
    var sensitivity: Double {
        get { defaults.double(forKey: Key.sensitivity).clamped(to: Limits.sensitivity) }
        set { set(newValue.clamped(to: Limits.sensitivity), forKey: Key.sensitivity) }
    }

    var horizontalColor: NSColor {
        get { color(forKey: Key.horizontalColor) ?? Defaults.horizontalColor }
        set { set(color: newValue, forKey: Key.horizontalColor) }
    }

    var verticalColor: NSColor {
        get { color(forKey: Key.verticalColor) ?? Defaults.verticalColor }
        set { set(color: newValue, forKey: Key.verticalColor) }
    }

    /// UID CoreAudio del dispositivo de entrada elegido. `nil` = entrada por defecto del sistema.
    var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { set(newValue, forKey: Key.inputDeviceUID) }
    }

    func resetToDefaults() {
        for key in [Key.enabled, Key.intensity, Key.thickness, Key.horizontalColor,
                    Key.verticalColor, Key.sensitivity, Key.inputDeviceUID] {
            defaults.removeObject(forKey: key)
        }
        notifyChange()
    }

    // MARK: - Internos

    private func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func set(color: NSColor, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color,
                                                           requiringSecureCoding: true) else { return }
        set(data, forKey: key)
    }

    private func color(forKey key: String) -> NSColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: PreferencesManager.didChangeNotification, object: self)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
