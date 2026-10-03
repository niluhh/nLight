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

// El código de nivel superior no está aislado a ningún actor, pero aquí se
// ejecuta en el hilo principal antes de que exista nada más. `assumeIsolated`
// lo hace explícito para poder construir el delegado, que sí es @MainActor.
// El resultado se guarda en una constante de nivel superior porque
// `NSApplication.delegate` es una referencia débil.
let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    return delegate
}

application.run()
