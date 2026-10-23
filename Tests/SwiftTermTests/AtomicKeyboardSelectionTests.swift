#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class AtomicKeyboardSelectionTests: XCTestCase {
    func testDownStopsAtLastExistingBufferRow() {
        let view = makeView(cols: 8, rows: 3)
        let lastRow = Optional(view.terminal.buffer.lines.count - 1)
        XCTAssertNotNil(lastRow)
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: lastRow ?? 0))

        view.extendSelection(direction: .down, byWord: false)

        XCTAssertEqual(view.selection.end, Position(col: 0, row: lastRow ?? 0))
    }

    func testWordMovementCrossesMultipleRowsAndBlankLines() {
        let view = makeView(cols: 6, rows: 4)
        view.terminal.feed(text: "one \r\n\r\n  two")
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))

        view.extendSelection(direction: .right, byWord: true)

        XCTAssertEqual(view.selection.end, Position(col: 2, row: 2))
    }

    func testCharacterMovementSelectsWholeWideGrapheme() throws {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "a界b")
        view.selection.setSoftStart(bufferPosition: Position(col: 1, row: 0))

        view.extendSelection(direction: .right, byWord: false)

        XCTAssertEqual(view.selection.end, Position(col: 3, row: 0))
        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "界")
    }

    func testMovingLeftDoesNotStopOnWideGlyphContinuationCell() throws {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "a界b")
        view.selection.setSoftStart(bufferPosition: Position(col: 3, row: 0))

        view.extendSelection(direction: .left, byWord: false)

        XCTAssertEqual(view.selection.end, Position(col: 1, row: 0))
        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "界")
    }

    func testCharacterMovementTreatsEmojiClusterAsOneGlyph() throws {
        let view = makeView(cols: 12, rows: 3)
        let emoji = "👩‍👩‍👦‍👦"
        view.terminal.feed(text: "a\(emoji)b")
        view.selection.setSoftStart(bufferPosition: Position(col: 1, row: 0))

        view.extendSelection(direction: .right, byWord: false)

        XCTAssertEqual(try XCTUnwrap(view.getSelection()), emoji)
        XCTAssertGreaterThan(view.selection.end.col, 1)
    }

    func testBidiTextUsesLogicalBufferOrder() throws {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "אב")
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))

        view.extendSelection(direction: .right, byWord: false)

        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "א")
    }

    func testVerticalMovementNormalizesWideGlyphContinuationColumn() {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "xx\r\na界")
        view.selection.setSoftStart(bufferPosition: Position(col: 2, row: 0))

        view.extendSelection(direction: .down, byWord: false)

        XCTAssertEqual(view.selection.end, Position(col: 1, row: 1))
    }

    func testWordMovementTreatsSoftWrapAsOneLogicalWord() {
        let view = makeView(cols: 5, rows: 3)
        view.terminal.feed(text: "abcdef ghi")
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))

        view.extendSelection(direction: .right, byWord: true)

        XCTAssertEqual(view.selection.end, Position(col: 2, row: 1))
    }

    func testFirstKeyboardSelectionAnchorsAtTerminalCursor() throws {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "abc")

        view.extendSelection(direction: .left, byWord: false)

        XCTAssertEqual(view.selection.start, Position(col: 3, row: 0))
        XCTAssertEqual(view.selection.end, Position(col: 2, row: 0))
        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "c")
    }

    func testCharacterMovementResetsStaleMouseWordSelectionMode() throws {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "abc")
        view.selection.selectWordOrExpression(
            at: Position(col: 0, row: 0),
            in: view.terminal.buffer
        )
        // SwiftTerm uses this direct transition on ordinary key input and
        // resize, leaving the previous selection mode intact.
        view.selection.active = false

        view.extendSelection(direction: .left, byWord: false)

        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "c")
    }

    func testKeyboardMovementClearsStaleMouseRowSelectionState() {
        let view = makeView(cols: 8, rows: 3)
        view.terminal.feed(text: "abc")
        view.selection.select(row: 0)
        view.selection.active = false
        XCTAssertTrue(view.selection.selectingRows)

        view.extendSelection(direction: .left, byWord: false)

        XCTAssertFalse(view.selection.selectingRows)
    }

    func testFirstKeyboardSelectionAnchorsAtCursorWhileViewportIsScrolledUp() {
        let view = makeView(cols: 8, rows: 3)
        for index in 0..<8 {
            view.terminal.feed(text: "line\(index)\r\n")
        }
        view.scrollTo(row: 0)

        let expected = Position(col: view.terminal.buffer.x, row: view.terminal.buffer.yBase + view.terminal.buffer.y)
        view.extendSelection(direction: .left, byWord: false)

        XCTAssertEqual(view.selection.start, expected)
    }

    func testLineEndIncludesContentInFinalColumn() throws {
        let view = makeView(cols: 5, rows: 3)
        view.terminal.feed(text: "abcde")
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))

        view.extendSelection(direction: .lineEnd, byWord: false)

        XCTAssertEqual(view.selection.end, Position(col: 5, row: 0))
        XCTAssertEqual(try XCTUnwrap(view.getSelection()), "abcde")
    }

    private func makeView(cols: Int, rows: Int) -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: cols, rows: rows))
        return view
    }
}

#endif
