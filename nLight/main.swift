//
//  main.swift
//  nLight
//
//  Arranque explícito de la app: nLight no usa nib principal, así que crea la
//  NSApplication y le asigna el AppDelegate directamente.
//

import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
