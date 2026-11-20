@testable import SaySoDictation
import XCTest

final class AudioMathTests: XCTestCase {
    func testResampleSameRateIsIdentity() {
        let input: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(AudioMath.resample(input, from: 16_000), input)
    }

    func testDownsample48kTo16kAveragesWindows() {
        let input: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertEqual(AudioMath.resample(input, from: 48_000, to: 16_000), [2, 5, 8])
    }

    func testDownsampleKeepsDuration() {
        let input = [Float](repeating: 0.5, count: 44_100)
        let out = AudioMath.resample(input, from: 44_100)
        XCTAssertEqual(out.count, 16_000)
        XCTAssertEqual(out.first!, 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.duration(of: out.count), 1, accuracy: 1e-9)
    }

    func testDownsamplePreservesLowFrequencySine() {
        // 440 Hz a 48 kHz → 16 kHz: el RMS debe mantenerse cerca de 1/√2.
        let input = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let out = AudioMath.resample(input, from: 48_000)
        XCTAssertEqual(out.count, 16_000)
        XCTAssertEqual(AudioMath.rms(out), 0.707, accuracy: 0.02)
    }

    func testUpsampleInterpolates() {
        let out = AudioMath.resample([0, 1], from: 8_000, to: 16_000)
        XCTAssertEqual(out, [0, 0.5, 1, 1])
    }

    func testResampleEdgeCases() {
        XCTAssertEqual(AudioMath.resample([], from: 48_000), [])
        XCTAssertEqual(AudioMath.resample([1, 2], from: 0), [])
        XCTAssertEqual(AudioMath.resample([1], from: 48_000), [])
    }

    func testDownmixAveragesChannels() {
        XCTAssertEqual(AudioMath.downmix([[1, 0, 1], [0, 0, 1, 9]]), [0.5, 0, 1])
        XCTAssertEqual(AudioMath.downmix([[0.3]]), [0.3])
        XCTAssertEqual(AudioMath.downmix([]), [])
    }

    func testRMS() {
        XCTAssertEqual(AudioMath.rms([]), 0)
        XCTAssertEqual(AudioMath.rms([1, -1, 1, -1]), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.rms([3, 4]), (12.5 as Float).squareRoot(), accuracy: 1e-6)
    }

    func testLevelRange() {
        XCTAssertEqual(AudioMath.level([]), 0)
        XCTAssertEqual(AudioMath.level([0, 0, 0]), 0)
        XCTAssertEqual(AudioMath.level([1, -1, 1]), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.level([10, -10]), 1, "Se recorta a 1")
        // -25 dBFS está a mitad de la escala de -50…0.
        let amplitude = Float(pow(10, -25.0 / 20))
        XCTAssertEqual(AudioMath.level([amplitude, -amplitude]), 0.5, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.level([0.001]), 0, "Por debajo de -50 dBFS es silencio")
    }

    func testLevelIsMonotonic() {
        let levels = [0.01, 0.05, 0.1, 0.5].map { AudioMath.level([Float($0), Float(-$0)]) }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertLessThan(levels.first!, levels.last!)
    }

    // MARK: - Utilidades de Whisper

    func testWhisperLanguageCode() {
        XCTAssertEqual(WhisperTranscriber.whisperLanguage("es-ES"), "es")
        XCTAssertEqual(WhisperTranscriber.whisperLanguage("en_US"), "en")
        XCTAssertEqual(WhisperTranscriber.whisperLanguage("ca"), "ca")
        XCTAssertNil(WhisperTranscriber.whisperLanguage(nil))
        XCTAssertNil(WhisperTranscriber.whisperLanguage(""))
    }

    func testWhisperCleanup() {
        XCTAssertEqual(WhisperTranscriber.clean("  [BLANK_AUDIO] "), "")
        XCTAssertEqual(WhisperTranscriber.clean(" Hola,  ¿qué tal? (música) "), "Hola, ¿qué tal?")
        XCTAssertEqual(WhisperTranscriber.clean("<|es|> Buenos días"), "Buenos días")
    }

    func testModelStatusLabels() {
        XCTAssertEqual(WhisperModelStatus.downloading(progress: 0.42).label, "Descargando modelo… 42 %")
        XCTAssertEqual(WhisperModelStatus.loading.label, "Cargando modelo…")
        XCTAssertEqual(WhisperModelStatus.ready.label, "Listo")
        XCTAssertEqual(WhisperModelStatus.failed("x").label, "Error: x")
    }
}
