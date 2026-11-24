import Foundation
import Testing
@testable import BasilCore

@Suite struct ThemeTests {
    @Test func basilsOwnColoursPassTheContrastRules() {
        let problems = ThemeContrast.problems(.builtin)
        #expect(problems.isEmpty, "\(problems.map(\.description))")
    }

    @Test func contrastRatiosAreWCAGs() {
        #expect(abs(ThemeContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(ThemeContrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(ThemeContrast.ratio(0x123456, 0x123456) == 1)
    }

    @Test func themesRoundTripAsJSONAndKeepUnknownColoursOut() throws {
        var theme = ThemeDefinition(id: "mine", name: "Mine")
        theme.colors[.text] = ThemeColor(light: 0x101010, dark: 0xEEEEEE)
        let data = try JSONEncoder().encode(theme)
        #expect(String(decoding: data, as: UTF8.self).contains("\"#101010\""))
        #expect(try JSONDecoder().decode(ThemeDefinition.self, from: data) == theme)
        let other = Data(##"{"name": "Odd", "colors": {"text": {"light": "#abc", "dark": "000000"}, "sparkles": {"light": "#FFFFFF", "dark": "#000000"}}}"##.utf8)
        let read = try JSONDecoder().decode(ThemeDefinition.self, from: other)
        #expect(read.colors == [.text: ThemeColor(light: 0xAABBCC, dark: 0x000000)])
        #expect(read.color(.paneBackground) == ThemeDefinition.builtin.color(.paneBackground))
        let bad = Data(##"{"name": "Bad", "colors": {"text": {"light": "red", "dark": "#000000"}}}"##.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ThemeDefinition.self, from: bad) }
    }

    @Test func unreadablePairsAreFound() {
        var theme = ThemeDefinition.builtin
        theme.colors[.text] = ThemeColor(light: 0xDDDDDD, dark: 0xE4E4E4)
        let problems = ThemeContrast.problems(theme)
        #expect(problems.contains { $0.pair.foreground == .text && $0.pair.background == .paneBackground && !$0.dark })
        #expect(!problems.contains { $0.dark })
        #expect(problems.first?.description.hasPrefix("Text on pane background would be 1.") == true)
    }
}
