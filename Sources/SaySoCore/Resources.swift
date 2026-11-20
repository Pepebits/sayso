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
    public var measuredAt: Date

    public init(disk: [Item], appMemory: Int64, vmMemory: Int64?, vmRunning: Bool, measuredAt: Date = Date()) {
        self.disk = disk.sorted { $0.bytes > $1.bytes }
        self.appMemory = appMemory
        self.vmMemory = vmMemory
        self.vmRunning = vmRunning
        self.measuredAt = measuredAt
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
