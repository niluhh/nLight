//
//  main.swift
//  nLight
//
//  Arranque explícito de la app: nLight no usa nib principal, así que crea la
//  NSApplication y le asigna el AppDelegate directamente.
//

import AppKit

// Red de seguridad: si alguna API de Objective-C lanzara una NSException, el
// proceso muere sin dejar rastro útil. Esto la registra con el prefijo [nLight]
// para que quede en Consola junto al resto del diagnóstico de audio.
NSSetUncaughtExceptionHandler { exception in
    NSLog("[nLight] EXCEPCIÓN NO CAPTURADA: %@ — %@\n%@",
          exception.name.rawValue,
          exception.reason ?? "sin motivo",
          exception.callStackSymbols.joined(separator: "\n"))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
