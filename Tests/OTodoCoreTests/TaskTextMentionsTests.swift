import Foundation
import XCTest
@testable import OTodoCore

final class TaskTextMentionsTests: XCTestCase {
    func testRecognizesWholeKnownLabelsInAppearanceOrderWithoutConsumingPunctuation() {
        let text = "(@HOME), @work. @workspace @work.example @unknown; “@home”\n@www.example"
        let mentions = TaskTextMentions(in: text, marker: "@")
        XCTAssertEqual(mentions.tokens.map(\.value), [
            "HOME", "work", "workspace", "work.example", "unknown", "home", "www.example",
        ])
        XCTAssertEqual(mentions.recognizedValues(from: ["Work", "Home", "www.example"]), ["Home", "Work", "www.example"])
        XCTAssertEqual(mentions.tokens[1].utf16Range, (text as NSString).range(of: "@work"))
        XCTAssertTrue(TaskTextMentions(in: "@workspace @work.example", marker: "@").recognizedValues(from: ["work"]).isEmpty)
    }

    func testEmailsURLsEscapesAndWordSuffixesDoNotBecomeMentionsOrCompletions() {
        let excluded = [
            "mail@work", "first.last+mail@work", "suffix@work", "word_@work", "word-@work",
            #"\@work"#, #"folder\@work"#, "folder/@work", "//example.test/@work",
            "https://@work", "https://user:@work/path", "https://example.test/@work",
            "https://example.test?q=(@work)", "//example.test?(@work)", "www.example.test?(@work)", "mailto:@work",
        ]
        for excludedText in excluded {
            let text = excludedText + "\n(@home)"
            let mentions = TaskTextMentions(in: text, marker: "@")
            XCTAssertEqual(mentions.recognizedValues(from: ["work", "home"]), ["home"], excludedText)
            let mentionRange = (text as NSString).range(of: "@work")
            XCTAssertTrue(mentions.suggestions(
                at: NSRange(location: NSMaxRange(mentionRange), length: 0), choices: ["work-app"]
            ).isEmpty, excludedText)
        }
    }

    func testMidTokenCompletionPreservesUnicodePrefixAndSentencePunctuation() throws {
        let (text, selection) = caret("\u{1D11E} Notes: (@wo¦rong), keep @home.")
        let suggestion = try XCTUnwrap(TaskTextMentions(in: text, marker: "@").suggestions(
            at: selection, choices: ["Work"]
        ).first)
        let result = try XCTUnwrap(suggestion.applying(to: text))
        XCTAssertEqual(result.text, "\u{1D11E} Notes: (@Work), keep @home.")
        XCTAssertEqual(result.selection, NSRange(location: "\u{1D11E} Notes: (@Work".utf16.count, length: 0))

        let (sentence, end) = caret("Send to @wo¦.")
        let completed = try XCTUnwrap(TaskTextMentions(in: sentence, marker: "@").suggestions(
            at: end, choices: ["work"]
        ).first?.applying(to: sentence))
        XCTAssertEqual(completed.text, "Send to @work.")
    }

    func testSelectionWithinDecomposedLabelReplacesWholeTokenWithCanonicalSpelling() throws {
        let text = "\u{1D11E} @re\u{301}old; @home"
        let selection = (text as NSString).range(of: "old")
        let result = try XCTUnwrap(TaskTextMentions(in: text, marker: "@").suggestions(
            at: selection, choices: ["résumé"]
        ).first?.applying(to: text))
        XCTAssertEqual(result.text, "\u{1D11E} @résumé; @home")
        XCTAssertEqual(result.selection, NSRange(location: "\u{1D11E} @résumé".utf16.count, length: 0))
    }

    func testUnicodeLabelsUseUTF16RangesAndRejectSplitSurrogatesAndInvalidSelections() {
        let value = "𐐀cafe\u{301}_2-v.example"
        let text = "\u{1D11E} @" + value + "."
        let mentions = TaskTextMentions(in: text, marker: "@")
        XCTAssertEqual(mentions.recognizedValues(from: [value]), [value])
        XCTAssertEqual(mentions.tokens.first?.utf16Range, (text as NSString).range(of: "@" + value))
        let splitSurrogate = "\u{1D11E} @".utf16.count + 1
        for selection in [
            NSRange(location: splitSurrogate, length: 0),
            NSRange(location: splitSurrogate, length: 1),
            NSRange(location: -1, length: 0),
            NSRange(location: text.utf16.count + 1, length: 0),
            NSRange(location: 0, length: Int.max),
            NSRange(location: NSNotFound, length: 0),
        ] {
            XCTAssertTrue(mentions.suggestions(at: selection, choices: [value]).isEmpty, "\(selection)")
        }
    }

    func testCrossTokenSelectionsAndStaleSnapshotsCannotRemoveOtherText() throws {
        let text = "é @wo and @home"
        let mentions = TaskTextMentions(in: text, marker: "@")
        let tokenRange = (text as NSString).range(of: "@wo")
        XCTAssertTrue(mentions.suggestions(
            at: NSRange(location: tokenRange.location, length: text.utf16.count - tokenRange.location),
            choices: ["work"]
        ).isEmpty)
        let suggestion = try XCTUnwrap(mentions.suggestions(
            at: NSRange(location: NSMaxRange(tokenRange), length: 0), choices: ["work"]
        ).first)
        XCTAssertNil(suggestion.applying(to: "é @xx and @home"))
        XCTAssertNil(suggestion.applying(to: "x @wo and @home"))
        XCTAssertNil(suggestion.applying(to: "e\u{301} @wo and @home"))
        XCTAssertNil(suggestion.applying(to: "é @"))
    }

    func testBareMarkerAndCompletedTokenSuggestionsRespectCaretAndCanonicalCase() throws {
        let (text, selection) = caret("Try (#¦), not @work")
        let suggestions = TaskTextMentions(in: text, marker: "#").suggestions(
            at: selection, choices: ["", "work", "work"]
        )
        XCTAssertEqual(suggestions.map(\.value), ["work"])
        XCTAssertEqual(try XCTUnwrap(suggestions.first?.applying(to: text)).text, "Try (#work), not @work")

        let complete = TaskTextMentions(in: "@work", marker: "@")
        XCTAssertTrue(complete.suggestions(at: NSRange(location: 5, length: 0), choices: ["work"]).isEmpty)
        XCTAssertEqual(complete.suggestions(at: NSRange(location: 3, length: 0), choices: ["work"]).map(\.value), ["work"])
        XCTAssertTrue(complete.suggestions(at: NSRange(location: 0, length: 0), choices: ["work"]).isEmpty)
        let canonical = try XCTUnwrap(complete.suggestions(
            at: NSRange(location: 5, length: 0), choices: ["Work"]
        ).first?.applying(to: "@work"))
        XCTAssertEqual(canonical.text, "@Work")
    }

    private func caret(_ markedText: String) -> (String, NSRange) {
        let marker = (markedText as NSString).range(of: "¦")
        return (markedText.replacingOccurrences(of: "¦", with: ""), NSRange(location: marker.location, length: 0))
    }
}
