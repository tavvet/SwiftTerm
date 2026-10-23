#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class AtomicScreenClearTests: XCTestCase {
    func testClearPreservesInputAndCursorWithoutSendingBytes() {
        let transport = RecordingClearTransport()
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 40, rows: 5))
        view.terminalDelegate = transport
        let terminal = view.terminal!
        terminal.feed(text: "old output\r\n\r\n$ echo pending")
        terminal.feed(text: "\u{1B}[3D")
        let cursor = terminal.getCursorLocation()

        XCTAssertTrue(view.clearPreviousOutput())

        XCTAssertEqual(terminal.bufferLine(atRow: 0)?.translateToString(trimRight: true), "")
        XCTAssertEqual(terminal.bufferLine(atRow: 2)?.translateToString(trimRight: true), "$ echo pending")
        XCTAssertEqual(terminal.getCursorLocation().x, cursor.x)
        XCTAssertEqual(terminal.getCursorLocation().y, cursor.y)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testClearPreservesEntireSoftWrappedInputIncludingPendingWrap() {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 6, rows: 5))
        let terminal = view.terminal!
        terminal.feed(text: "old\r\n$ abcdefghij")
        let original = terminal.getText(start: Position(col: 0, row: 1), end: Position(col: 6, row: 2))
        let cursor = terminal.getCursorLocation()

        XCTAssertTrue(view.clearPreviousOutput())

        XCTAssertEqual(terminal.getText(start: Position(col: 0, row: 1), end: Position(col: 6, row: 2)), original)
        XCTAssertEqual(terminal.getCursorLocation().x, cursor.x)
        XCTAssertEqual(terminal.getCursorLocation().y, cursor.y)
        XCTAssertEqual(terminal.bufferLine(atRow: 2)?.isWrapped, true)
    }

    func testClearDoesNotInterruptPartiallyReceivedEscapeSequence() {
        let transport = RecordingClearTransport()
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 40, rows: 5))
        view.terminalDelegate = transport
        let terminal = view.terminal!
        terminal.feed(text: "old output\r\n$ pending\u{1B}[")
        let cursor = terminal.getCursorLocation()

        XCTAssertTrue(view.clearPreviousOutput())
        terminal.feed(text: "3D")

        XCTAssertEqual(terminal.getCursorLocation().x, cursor.x - 3)
        XCTAssertEqual(terminal.getCursorLocation().y, cursor.y)
        XCTAssertEqual(terminal.bufferLine(atRow: 1)?.translateToString(trimRight: true), "$ pending")
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testClearPreservesHardLineBreaksInsideSemanticPrompt() {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 40, rows: 5))
        let terminal = view.terminal!
        terminal.feed(text: "old output\r\n\u{1B}]133;A\u{7}directory\r\n$ \u{1B}]133;B\u{7}echo pending")

        XCTAssertTrue(view.clearPreviousOutput())

        XCTAssertEqual(terminal.bufferLine(atRow: 0)?.translateToString(trimRight: true), "")
        XCTAssertEqual(terminal.bufferLine(atRow: 1)?.translateToString(trimRight: true), "directory")
        XCTAssertEqual(terminal.bufferLine(atRow: 2)?.translateToString(trimRight: true), "$ echo pending")
    }

    func testClearDoesNotAlterAlternateScreen() {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 20, rows: 4))
        let terminal = view.terminal!
        terminal.feed(text: "\u{1B}[?1049hfirst\r\nsecond")
        let original = view.getBufferAsData()

        XCTAssertFalse(view.clearPreviousOutput())
        XCTAssertEqual(view.getBufferAsData(), original)
    }

    func testRunningCommandDoesNotPreserveAnOldPromptAndAllItsOutput() {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 40, rows: 5))
        let terminal = view.terminal!
        terminal.feed(text: "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}long-command\r\n\u{1B}]133;C\u{7}old output\r\nlatest output")

        XCTAssertTrue(view.clearPreviousOutput(preservePrompt: false))

        XCTAssertEqual(terminal.bufferLine(atRow: 0)?.translateToString(trimRight: true), "")
        XCTAssertEqual(terminal.bufferLine(atRow: 1)?.translateToString(trimRight: true), "")
        XCTAssertEqual(terminal.bufferLine(atRow: 2)?.translateToString(trimRight: true), "latest output")
        XCTAssertTrue(terminal.semanticPromptMarks(at: 0).isEmpty)
    }

}

@MainActor
private final class RecordingClearTransport: TerminalViewDelegate {
    var sent: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
