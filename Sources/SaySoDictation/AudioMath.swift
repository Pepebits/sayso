import Foundation

/// Funciones puras de audio: mezcla, remuestreo y nivel.
public enum AudioMath {
    /// Frecuencia que espera el transcriptor.
    public static let targetSampleRate: Double = 16_000

    /// Mezcla varios canales a mono promediando.
    public static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let count = channels.map(\.count).min() ?? 0
        let scale = 1 / Float(channels.count)
        var out = [Float](repeating: 0, count: count)
        for channel in channels {
            for i in 0..<count { out[i] += channel[i] }
        }
        for i in 0..<count { out[i] *= scale }
        return out
    }

    /// Remuestrea a otra frecuencia. Al reducir, promedia la ventana de origen
    /// (filtro paso bajo sencillo); al aumentar, interpola linealmente.
    public static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double = targetSampleRate) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 0.5 { return samples }
        let ratio = sourceRate / targetRate
        let outCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        if ratio > 1 {
            for i in 0..<outCount {
                let start = Int((Double(i) * ratio).rounded(.down))
                let end = min(samples.count, max(start + 1, Int((Double(i + 1) * ratio).rounded(.down))))
                var sum: Float = 0
                for j in start..<end { sum += samples[j] }
                out[i] = sum / Float(end - start)
            }
        } else {
            let last = samples.count - 1
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let index = Int(pos)
                let frac = Float(pos - Double(index))
                let a = samples[min(index, last)]
                let b = samples[min(index + 1, last)]
                out[i] = a + (b - a) * frac
            }
        }
        return out
    }

    /// Valor cuadrático medio.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Nivel 0…1 para la forma de onda: RMS en dBFS llevado de [floorDB, 0] a [0, 1].
    public static func level(_ samples: [Float], floorDB: Float = -50) -> Float {
        let value = rms(samples)
        guard value > 0 else { return 0 }
        let db = 20 * log10(value)
        return min(1, max(0, (db - floorDB) / -floorDB))
    }

    /// Duración en segundos.
    public static func duration(of count: Int, sampleRate: Double = targetSampleRate) -> TimeInterval {
        sampleRate > 0 ? Double(count) / sampleRate : 0
    }
}
