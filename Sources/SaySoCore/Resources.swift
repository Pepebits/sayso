import Foundation

// Lo que ocupa SaySo en este Mac: disco por partes y memoria. Para la sección Recursos de
// Estadísticas, y para saber qué optimizar.

public struct ResourceUsage: Hashable, Sendable {
    /// Una parte de lo que ocupa en disco.
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var bytes: Int64
        /// Aclaración breve («de 16 GB como mucho»).
        public var detail: String?

        public init(id: String, title: String, bytes: Int64, detail: String? = nil) {
            self.id = id
            self.title = title
            self.bytes = bytes
            self.detail = detail
        }
    }

    /// De mayor a menor.
    public var disk: [Item]
    /// Memoria que usa la app ahora mismo (la «Memoria» del Monitor de Actividad).
    public var appMemory: Int64
    /// Memoria asignada a la máquina Linux; `nil` si no está instalada.
    public var vmMemory: Int64?
    public var vmRunning: Bool
    /// Memoria que usa de verdad la máquina Linux, si está en marcha.
    public var vmMemoryUsed: Int64?
    /// Qué ocupa dentro de la máquina Linux, si está en marcha (detector, Python, archivos…).
    public var vmInside: [Item]?
    public var measuredAt: Date

    public init(disk: [Item], appMemory: Int64, vmMemory: Int64?, vmRunning: Bool, measuredAt: Date = Date()) {
        self.disk = disk.sorted { $0.bytes > $1.bytes }
        self.appMemory = appMemory
        self.vmMemory = vmMemory
        self.vmRunning = vmRunning
        self.measuredAt = measuredAt
    }

    /// Partes de la máquina Linux por las que se pregunta, con su nombre.
    /// `path` es lo que se le pasa a `du`; `suffix`, cómo termina la ruta que devuelve.
    public static let vmPaths: [(path: String, suffix: String, id: String, title: String)] = [
        ("$HOME/.sayso-guard/venv", "/.sayso-guard/venv", "guard-python", "Detector: Python y PyTorch"),
        ("$HOME/sayso", "/sayso", "agent-files", "Archivos del agente"),
        ("$HOME/.local", "/.local", "agent-programs", "Programas instalados por el agente"),
        ("$HOME/.cache", "/.cache", "caches", "Cachés (pip, navegador…)"),
        ("/var/cache/apt", "/var/cache/apt", "apt", "Paquetes descargados (apt)"),
    ]

    /// Todo lo que se mide dentro de la máquina, modelos del detector incluidos.
    public static var vmQuery: [String] { ["$HOME/.sayso-guard/models/*"] + vmPaths.map(\.path) }

    /// Prefijo de los modelos del detector: `guard:<carpeta>`.
    public static let guardModelPrefix = "guard:"

    /// Convierte la respuesta de `du` en partes con nombre. `used` es lo que ocupa todo el sistema de
    /// archivos: lo que no cae en ninguna parte es el sistema.
    public static func vmItems(_ usage: [(path: String, bytes: UInt64)], used: UInt64?, activeModelFolder: String?) -> [Item] {
        var items: [Item] = []
        for (path, bytes) in usage where bytes > 0 {
            if let range = path.range(of: "/.sayso-guard/models/") {
                let folder = String(path[range.upperBound...])
                let repo = folder.replacingOccurrences(of: "--", with: "/")
                items.append(Item(id: guardModelPrefix + folder, title: repo, bytes: Int64(bytes),
                                  detail: folder == activeModelFolder ? tr("detector de inyecciones, en uso") : tr("detector de inyecciones, sin usar")))
            } else if let known = vmPaths.first(where: { path.hasSuffix($0.suffix) }) {
                items.append(Item(id: known.id, title: known.title, bytes: Int64(bytes)))
            }
        }
        if let used {
            let counted = items.reduce(Int64(0)) { $0 + $1.bytes }
            let rest = Int64(used) - counted
            if rest > 0 { items.append(Item(id: "system", title: "Sistema (Debian)", bytes: rest)) }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    public var totalDisk: Int64 { disk.reduce(0) { $0 + $1.bytes } }
}

public enum DiskMeasure {
    /// Espacio que ocupa de verdad en disco un archivo o una carpeta. Con los archivos dispersos
    /// (el disco de la máquina Linux) es mucho menos que su tamaño nominal.
    public static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: keys), v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Memoria física que usa este proceso (`phys_footprint`, la misma que enseña el Monitor de Actividad).
    public static func appMemory() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
