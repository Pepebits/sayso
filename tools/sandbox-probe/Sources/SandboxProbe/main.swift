import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import IOKit.hid
import Security
import SwiftUI
import Virtualization

// App de prueba: comprueba, dentro del App Sandbox, las mismas llamadas del sistema que usa SaySo.
// Cada resultado se enseña en la ventana y se escribe en la salida estándar como
// «nombre <tab> OK|FALLA|PENDIENTE <tab> detalle», para poder leerlo desde fuera.

enum Outcome: String { case ok = "OK", fail = "FALLA", pending = "PENDIENTE" }

struct Check: Identifiable {
    let id: String
    var title: String
    var outcome: Outcome
    var detail: String
}

@MainActor
final class Probe: ObservableObject {
    @Published var checks: [Check] = []
    @Published var optionPresses = 0
    @Published var countdown: Int?
    private var tap: CFMachPort?
    private var vm: VZVirtualMachine?

    func report(_ id: String, _ title: String, _ outcome: Outcome, _ detail: String) {
        let check = Check(id: id, title: title, outcome: outcome, detail: detail)
        if let index = checks.firstIndex(where: { $0.id == id }) { checks[index] = check } else { checks.append(check) }
        print("\(id)\t\(outcome.rawValue)\t\(detail.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)
    }

    // MARK: Sin intervención

    func runAutomatic() async {
        let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        report("sandbox", "Sandbox activo", container != nil ? .ok : .fail,
               container.map { "contenedor \($0); carpeta \(NSHomeDirectory())" } ?? "la app NO está en sandbox")
        checkFiles()
        await checkNetwork()
        checkKeychain()
        await checkVirtualMachine()
        checkVolumeScript()
        refreshPermissions()
    }

    private func supportFolder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("SaySoProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func checkFiles() {
        do {
            let file = try supportFolder().appendingPathComponent("prueba.txt")
            try Data("hola".utf8).write(to: file)
            let back = try String(contentsOf: file, encoding: .utf8)
            report("datos", "Guardar datos propios", back == "hola" ? .ok : .fail, file.deletingLastPathComponent().path)
        } catch { report("datos", "Guardar datos propios", .fail, error.localizedDescription) }
        // Lo que hoy usa SaySo: la carpeta real de Application Support, fuera del contenedor.
        let real = "/Users/\(NSUserName())/Library/Application Support/SaySo/sayso.sqlite"
        let readable = FileManager.default.isReadableFile(atPath: real)
        report("datos-actuales", "Leer los datos actuales de SaySo", readable ? .ok : .fail,
               readable ? "se puede leer \(real)" : "bloqueado: habría que migrar los datos al contenedor")
    }

    private func checkNetwork() async {
        do {
            var request = URLRequest(url: URL(string: "https://api.telegram.org/")!, timeoutInterval: 15)
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request)
            report("red", "Red saliente (Telegram)", .ok, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch { report("red", "Red saliente (Telegram)", .fail, error.localizedDescription) }
    }

    private func checkKeychain() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.pepebits.sayso.sandboxprobe",
                                   kSecAttrAccount as String: "prueba"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("secreto".utf8)
        let added = SecItemAdd(add as CFDictionary, nil)
        var query = base
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let read = SecItemCopyMatching(query as CFDictionary, &out)
        SecItemDelete(base as CFDictionary)
        let ok = added == errSecSuccess && read == errSecSuccess && (out as? Data) == Data("secreto".utf8)
        report("llavero", "Llavero", ok ? .ok : .fail, "añadir=\(added) leer=\(read)")
    }

    /// Una máquina mínima con el mismo arranque EFI y la misma red NAT que usa SaySo, sin disco:
    /// basta para saber si la virtualización arranca dentro del sandbox.
    private func checkVirtualMachine() async {
        do {
            let folder = try supportFolder()
            let store = folder.appendingPathComponent("efi-vars")
            try? FileManager.default.removeItem(at: store)
            let configuration = VZVirtualMachineConfiguration()
            configuration.platform = VZGenericPlatformConfiguration()
            let boot = VZEFIBootLoader()
            boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: store)
            configuration.bootLoader = boot
            configuration.cpuCount = max(1, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
            configuration.memorySize = max(1 << 30, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            configuration.networkDevices = [network]
            // Un disco vacío creado en el contenedor, como el de SaySo pero pequeño.
            let disk = folder.appendingPathComponent("disco.raw")
            FileManager.default.createFile(atPath: disk.path, contents: nil)
            try FileHandle(forWritingTo: disk).truncate(atOffset: 64 << 20)
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))]
            try configuration.validate()
            let machine = VZVirtualMachine(configuration: configuration)
            vm = machine
            let watcher = StopWatcher()
            machine.delegate = watcher
            try await machine.start()
            // Si `start()` no falla, la máquina ha arrancado. Sin sistema que cargar, el firmware
            // puede apagarla enseguida: eso no es un fallo del sandbox, así que se anota aparte.
            let atStart = machine.state
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let later = machine.state
            if later == .running { try? await machine.stop() }
            vm = nil
            let problem = watcher.error.map { " · error: \($0)" } ?? ""
            report("vm", "Máquina virtual (EFI + red NAT)", watcher.error == nil ? .ok : .fail,
                   "start() correcto; estado al arrancar \(atStart.rawValue), 1,5 s después \(later.rawValue)"
                   + (watcher.guestStopped ? " (el invitado se apagó solo: no hay sistema en el disco)" : "") + problem)
        } catch { report("vm", "Máquina virtual (EFI + red NAT)", .fail, error.localizedDescription) }
    }

    private func osascript(_ lines: [String], timeout: TimeInterval = 25) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "no se pudo lanzar osascript: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return (-2, "sin respuesta en \(Int(timeout)) s") }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Lo que hace SaySo para el volumen: `set volume` por osascript. Aquí se lee y se vuelve a
    /// poner el mismo valor, para no cambiar nada.
    private func checkVolumeScript() {
        let read = osascript(["output volume of (get volume settings)"])
        guard read.status == 0, let level = Int(read.output) else {
            return report("volumen", "Volumen por osascript", .fail, "leer: \(read.status) \(read.output)")
        }
        let write = osascript(["set volume output volume \(level)"])
        report("volumen", "Volumen por osascript", write.status == 0 ? .ok : .fail,
               write.status == 0 ? "leído y repuesto al \(level) %" : "poner: \(write.status) \(write.output)")
    }

    // MARK: Con permisos del usuario

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        report("accesibilidad", "Permiso de Accesibilidad", trusted ? .ok : .pending,
               trusted ? "concedido" : "sin conceder")
        let listen = CGPreflightListenEventAccess()
        report("entrada", "Permiso de Supervisión de entrada", listen ? .ok : .pending,
               listen ? "concedido" : "sin conceder")
        startTap()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        report("microfono", "Micrófono", mic == .authorized ? .ok : (mic == .denied ? .fail : .pending),
               ["sin preguntar", "restringido", "denegado", "concedido"][Int(mic.rawValue)])
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        report("recordatorios", "Recordatorios (EventKit)", reminders == .fullAccess ? .ok : .pending,
               "estado \(reminders.rawValue)")
    }

    func askAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        report("accesibilidad-pedir", "Pedir Accesibilidad", .ok, "llamada hecha; concedido ahora mismo: \(trusted)")
    }

    func askInputMonitoring() {
        let granted = CGRequestListenEventAccess()
        report("entrada-pedir", "Pedir Supervisión de entrada", .ok, "llamada hecha; concedido ahora mismo: \(granted)")
    }

    func askMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.report("microfono-pedir", "Pedir micrófono", granted ? .ok : .fail, "concedido: \(granted)")
                self.refreshPermissions()
            }
        }
    }

    func askReminders() {
        EKEventStore().requestFullAccessToReminders { granted, error in
            Task { @MainActor in
                self.report("recordatorios-pedir", "Pedir Recordatorios", granted ? .ok : .fail,
                            error?.localizedDescription ?? "concedido: \(granted)")
                self.refreshPermissions()
            }
        }
    }

    /// La misma captura que usa SaySo para la tecla ⌥: solo escucha, en la sesión.
    func startTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: probeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return report("tecla", "Captura de teclado (tecla ⌥)", .pending, "no se pudo crear la captura")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0), .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        report("tecla", "Captura de teclado (tecla ⌥)", .pending, "captura creada; pulsa ⌥ con otra app delante")
    }

    private var seenFront: Set<String> = []
    func optionPressed(frontmost: String) {
        optionPresses += 1
        guard seenFront.insert(frontmost).inserted else { return }
        report("tecla", "Captura de teclado (tecla ⌥)", .ok,
               "⌥ detectada \(optionPresses) veces; app en primer plano: \(frontmost)")
    }

    /// Lo mismo que el insertador de SaySo: primero por Accesibilidad y, si no, pegando con ⌘V.
    func insertAfterCountdown() {
        Task {
            for second in stride(from: 5, to: 0, by: -1) {
                countdown = second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
            insert("hola desde el sandbox ")
        }
    }

    private func insert(_ text: String) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        // La prueba solo vale con OTRA app delante: escribir en esta misma no demuestra nada.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return report("insertar", "Escribir en otra app", .pending,
                          "no vale: SandboxProbe seguía delante. Pulsa el botón y cambia a TextEdit antes de 5 s")
        }
        guard AXIsProcessTrusted() else {
            return report("insertar", "Escribir en otra app", .pending,
                          "falta el permiso de Accesibilidad; sin él no se puede ni escribir ni simular ⌘V")
        }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if focusResult == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            let set = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if settable.boolValue, set == .success {
                return report("insertar", "Escribir en otra app", .ok, "por Accesibilidad, en \(front)")
            }
            report("insertar-ax", "Escribir por Accesibilidad", .fail,
                   "en \(front): editable=\(settable.boolValue) resultado=\(set.rawValue)")
        } else {
            report("insertar-ax", "Escribir por Accesibilidad", .fail,
                   "en \(front): no se pudo leer el campo con foco (resultado \(focusResult.rawValue))")
        }
        // Segundo camino: portapapeles y ⌘V simulado.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return report("insertar", "Escribir en otra app", .fail, "no se pudieron crear los eventos de teclado")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        report("insertar", "Escribir en otra app", .pending,
               "⌘V enviado a \(front); mira si ha aparecido «hola desde el sandbox»")
    }

    func confirmPaste(_ worked: Bool) {
        report("insertar", "Escribir en otra app", worked ? .ok : .fail,
               worked ? "pegando con ⌘V (confirmado por ti)" : "el ⌘V simulado no llegó a la otra app")
    }

    /// Lo mismo, pero enviando el evento desde esta app (NSAppleScript) y no desde un proceso hijo:
    /// es el camino que respeta los permisos de la app en sandbox.
    func checkNotesInProcess() {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Notes\" to count notes")?.executeAndReturnError(&error)
        if let result {
            report("notas-directo", "Hablar con Notas desde la app", .ok, "responde: \(result.int32Value) notas")
        } else {
            let number = error?[NSAppleScript.errorNumber] ?? "?"
            let message = error?[NSAppleScript.errorMessage] ?? "sin mensaje"
            report("notas-directo", "Hablar con Notas desde la app", .fail, "\(number) \(message)")
        }
    }

    /// Solo lee: cuenta las notas. Con la excepción de Apple Events macOS pedirá permiso.
    func checkNotes() {
        checkNotesInProcess()
        Task.detached {
            let result = await self.osascript(["tell application \"Notes\" to count notes"], timeout: 60)
            await MainActor.run {
                self.report("notas", "Hablar con Notas (Apple Events)", result.status == 0 ? .ok : .fail,
                            result.status == 0 ? "responde: \(result.output) notas" : "\(result.status) \(result.output)")
            }
        }
    }
}

final class StopWatcher: NSObject, VZVirtualMachineDelegate {
    var error: String?
    var guestStopped = false
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { guestStopped = true }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        self.error = error.localizedDescription
    }
}

private func probeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .flagsChanged, event.flags.contains(.maskAlternate), let userInfo {
        let probe = Unmanaged<Probe>.fromOpaque(userInfo).takeUnretainedValue()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Task { @MainActor in probe.optionPressed(frontmost: front) }
    }
    return Unmanaged.passUnretained(event)
}

struct ProbeView: View {
    @ObservedObject var probe: Probe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prueba de sandbox de SaySo").font(.title2.bold())
            Text("Esta app corre dentro del App Sandbox. Cada fila es una función de SaySo.")
                .foregroundStyle(.secondary)
            List(probe.checks) { check in
                HStack(alignment: .firstTextBaseline) {
                    Text(check.outcome.rawValue)
                        .font(.caption.monospaced().bold())
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(check.title).bold()
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 330)
            Text("Permisos").font(.headline)
            HStack {
                Button("Pedir Accesibilidad") { probe.askAccessibility() }
                Button("Pedir Supervisión de entrada") { probe.askInputMonitoring() }
                Button("Pedir micrófono") { probe.askMicrophone() }
                Button("Pedir Recordatorios") { probe.askReminders() }
            }
            Text("Pruebas").font(.headline)
            HStack {
                Button("Volver a comprobar permisos") { probe.refreshPermissions() }
                Button(probe.countdown.map { "Escribiendo en \($0)…" } ?? "Escribir en otra app en 5 s") {
                    probe.insertAfterCountdown()
                }
                .disabled(probe.countdown != nil)
                Button("Sí apareció") { probe.confirmPaste(true) }
                Button("No apareció") { probe.confirmPaste(false) }
                Button("Probar Notas") { probe.checkNotes() }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let probe = Probe()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SandboxProbe"
        window.contentView = NSHostingView(rootView: ProbeView(probe: probe))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if arguments.contains("--hid") {
            // Solo el permiso de teclado: qué dice macOS antes y después de pedirlo.
            func state() -> String {
                func hid(_ type: IOHIDRequestType) -> String {
                    switch IOHIDCheckAccess(type) {
                    case kIOHIDAccessTypeGranted: return "concedido"
                    case kIOHIDAccessTypeDenied: return "denegado"
                    default: return "sin-preguntar"
                    }
                }
                return "escuchar=\(hid(kIOHIDRequestTypeListenEvent)) enviar=\(hid(kIOHIDRequestTypePostEvent)) preflight=\(CGPreflightListenEventAccess()) ax=\(AXIsProcessTrusted())"
            }
            print("id\t\(Bundle.main.bundleIdentifier ?? "?")")
            print("antes\t\(state())")
            let asked = CGRequestListenEventAccess()
            print("CGRequestListenEventAccess\t\(asked)")
            print("despues\t\(state())")
            fflush(stdout)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                print("a-los-4s\t\(state())")
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }
        Task { @MainActor in
            await probe.runAutomatic()
            if arguments.contains("--notas") { probe.checkNotes(); try? await Task.sleep(nanoseconds: 8_000_000_000) }
            print("fin-automatico\tOK\t")
            fflush(stdout)
            if arguments.contains("--salir") { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
