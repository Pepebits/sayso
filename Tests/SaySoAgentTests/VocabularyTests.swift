import SaySoCore
import XCTest

final class VocabularyTests: XCTestCase {
    func testWritesWordsAsInTheDictionaryAndAppliesReplacements() {
        let out = DictationVocabulary.apply("escríbele a pepebits arroba gmail punto com sobre sayso",
                                            vocabulary: ["Pepebits", "SaySo"],
                                            replacements: [TextReplacement(from: "arroba", to: "@"),
                                                           TextReplacement(from: "punto com", to: ".com")])
        XCTAssertEqual(out, "escríbele a Pepebits @ gmail .com sobre SaySo")
    }

    func testOnlyWholeWords() {
        XCTAssertEqual(DictationVocabulary.apply("anabel y ana", vocabulary: ["Ana"], replacements: []), "anabel y Ana")
        XCTAssertEqual(DictationVocabulary.apply("ñandú", vocabulary: ["Ñan"], replacements: []), "ñandú")
    }

    func testCleanDropsEmptyAndRepeated() {
        XCTAssertEqual(DictationVocabulary.clean([" Pepebits ", "", "pepebits", "SaySo"]), ["Pepebits", "SaySo"])
        XCTAssertNil(DictationVocabulary.correctionHint([]))
        XCTAssertEqual(DictationVocabulary.correctionHint(["SaySo"]),
                       "Escribe exactamente así estos nombres y palabras cuando aparezcan: SaySo.")
    }

    func testOldSettingsDecodeWithoutDictionary() throws {
        let old = #"{"enabled":true,"side":"any","aiCorrection":false,"engine":"whisper","voiceMode":"agent","speakReplies":true}"#
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.vocabulary, [])
        XCTAssertEqual(settings.replacements, [])
        let round = try JSONDecoder().decode(DictationSettings.self,
                                             from: JSONEncoder().encode(DictationSettings(vocabulary: ["SaySo"],
                                                                                          replacements: [TextReplacement(from: "a", to: "b")])))
        XCTAssertEqual(round.vocabulary, ["SaySo"])
        XCTAssertEqual(round.replacements.first?.to, "b")
    }
}
