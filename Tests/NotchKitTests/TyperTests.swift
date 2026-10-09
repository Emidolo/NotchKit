import Carbon.HIToolbox
import Testing
@testable import NotchKit

@Test func turnsTextIntoKeystrokes() {
    #expect(Typer.keystrokes("a\tb") == [.text("a"), .key(kVK_Tab), .text("b")])
    // One Return per line break, whichever way the line ends.
    #expect(Typer.keystrokes("a\nb\r\nc\r") == [.text("a"), .key(kVK_Return), .text("b"), .key(kVK_Return), .text("c"), .key(kVK_Return)])
    // A character made of several code points is typed in one go.
    #expect(Typer.keystrokes("é👍🏽") == [.text("é"), .text("👍🏽")])
    #expect(Typer.keystrokes("").isEmpty)
}
