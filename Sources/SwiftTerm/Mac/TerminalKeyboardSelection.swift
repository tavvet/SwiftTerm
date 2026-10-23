import Foundation

#if os(macOS)
/// Keyboard movement expressed without exposing mutable terminal storage.
public enum TerminalSelectionDirection: Sendable {
    case left, right, up, down, lineStart, lineEnd
}

public struct TerminalSelectionSnapshot: Sendable, Equatable {
    public let active: Bool
    public let start: Position
    public let end: Position
}

@MainActor
extension TerminalView {
    /// Extends the selection atomically against the current buffer and cursor.
    @discardableResult
    public func extendSelection(direction: TerminalSelectionDirection, byWord: Bool = false)
        -> TerminalSelectionSnapshot {
        withTerminal { _ in
            extendKeyboardSelectionLocked(direction: direction, byWord: byWord)
            return selectionSnapshotLocked()
        }
    }

    public func selectionSnapshot() -> TerminalSelectionSnapshot {
        withTerminal { _ in selectionSnapshotLocked() }
    }

    private func selectionSnapshotLocked() -> TerminalSelectionSnapshot {
        TerminalSelectionSnapshot(active: selection.active, start: selection.start, end: selection.end)
    }

    /// Extends the in-buffer selection from the terminal cursor, or from the
    /// current selection endpoint when a selection is already active.
    private func extendKeyboardSelectionLocked(
        direction: TerminalSelectionDirection,
        byWord: Bool
    ) {
        guard terminal.cols > 0,
              let lastRow = KeyboardSelectionGeometry.lastBufferRow(in: terminal) else {
            return
        }

        // Mouse selection leaves its word/row mode behind when SwiftTerm
        // deactivates the range directly (for example on key input or resize).
        // Keyboard movement owns its own character/word stepping below, so do
        // not let SelectionService snap the destination a second time.
        selection.selectingRows = false
        selection.selectionMode = .character

        if !selection.active {
            guard let cursor = KeyboardSelectionGeometry.cursorBufferPosition(in: terminal) else {
                return
            }
            selection.setSoftStart(bufferPosition: cursor)
        }

        let destination = shadeKeyboardSelectionDestination(
            from: selection.end,
            direction: direction,
            byWord: byWord,
            lastRow: lastRow
        )
        selection.shiftExtend(bufferPosition: destination)
    }

    private func shadeKeyboardSelectionDestination(
        from start: Position,
        direction: TerminalSelectionDirection,
        byWord: Bool,
        lastRow: Int
    ) -> Position {
        switch direction {
        case .left:
            return byWord
                ? shadeKeyboardWordPositionLeft(from: start, lastRow: lastRow)
                : previousShadeKeyboardCharacter(from: start, lastRow: lastRow)
        case .right:
            return byWord
                ? shadeKeyboardWordPositionRight(from: start, lastRow: lastRow)
                : nextShadeKeyboardCharacter(from: start, lastRow: lastRow)
        case .up:
            return shadeKeyboardVerticalPosition(from: start, rowDelta: -1, lastRow: lastRow)
        case .down:
            return shadeKeyboardVerticalPosition(from: start, rowDelta: 1, lastRow: lastRow)
        case .lineStart:
            return Position(col: 0, row: clampedShadeKeyboardRow(start.row, lastRow: lastRow))
        case .lineEnd:
            let row = clampedShadeKeyboardRow(start.row, lastRow: lastRow)
            let col = KeyboardSelectionGeometry.line(atBufferRow: row, in: terminal)?
                .getTrimmedLength() ?? 0
            return Position(col: col, row: row)
        }
    }

    private func previousShadeKeyboardCharacter(from start: Position, lastRow: Int) -> Position {
        var position = clampedShadeKeyboardPosition(start, lastRow: lastRow)
        if position.col == 0 {
            guard position.row > 0 else { return position }
            position.row -= 1
            position.col = terminal.cols
        }

        position.col -= 1
        guard let line = KeyboardSelectionGeometry.line(atBufferRow: position.row, in: terminal) else {
            return position
        }
        while position.col > 0, line.getWidth(index: position.col) == 0 {
            position.col -= 1
        }
        return position
    }

    private func nextShadeKeyboardCharacter(from start: Position, lastRow: Int) -> Position {
        var position = clampedShadeKeyboardPosition(start, lastRow: lastRow)
        if position.col >= terminal.cols {
            guard position.row < lastRow else { return position }
            return Position(col: 0, row: position.row + 1)
        }

        guard let line = KeyboardSelectionGeometry.line(atBufferRow: position.row, in: terminal) else {
            return position
        }
        while position.col > 0, line.getWidth(index: position.col) == 0 {
            position.col -= 1
        }
        position.col += max(1, line.getWidth(index: position.col))
        if position.col >= terminal.cols, position.row < lastRow {
            return Position(col: 0, row: position.row + 1)
        }
        position.col = min(position.col, terminal.cols)
        return position
    }

    private func shadeKeyboardVerticalPosition(
        from start: Position,
        rowDelta: Int,
        lastRow: Int
    ) -> Position {
        let position = clampedShadeKeyboardPosition(start, lastRow: lastRow)
        let row = min(max(position.row + rowDelta, 0), lastRow)
        var col = position.col
        if col < terminal.cols,
           let line = KeyboardSelectionGeometry.line(atBufferRow: row, in: terminal) {
            while col > 0, line.getWidth(index: col) == 0 {
                col -= 1
            }
        }
        return Position(col: col, row: row)
    }

    private func shadeKeyboardWordPositionLeft(from start: Position, lastRow: Int) -> Position {
        var position = previousShadeKeyboardCharacter(from: start, lastRow: lastRow)
        while !isShadeKeyboardWordCharacter(at: position) {
            let previous = previousShadeKeyboardCharacter(from: position, lastRow: lastRow)
            guard previous != position else { return position }
            position = previous
        }

        while true {
            let previous = previousShadeKeyboardCharacter(from: position, lastRow: lastRow)
            guard previous != position,
                  isShadeKeyboardWordCharacter(at: previous) else { return position }
            position = previous
        }
    }

    private func shadeKeyboardWordPositionRight(from start: Position, lastRow: Int) -> Position {
        var position = clampedShadeKeyboardPosition(start, lastRow: lastRow)

        while isShadeKeyboardWordCharacter(at: position) {
            let next = nextShadeKeyboardCharacter(from: position, lastRow: lastRow)
            guard next != position else { return position }
            position = next
            if next.row != start.row,
               KeyboardSelectionGeometry.line(atBufferRow: next.row, in: terminal)?.isWrapped != true {
                break
            }
        }
        while !isShadeKeyboardWordCharacter(at: position) {
            let next = nextShadeKeyboardCharacter(from: position, lastRow: lastRow)
            guard next != position else { return position }
            position = next
        }
        return position
    }

    private func isShadeKeyboardWordCharacter(at position: Position) -> Bool {
        guard position.row >= 0,
              position.col >= 0,
              position.col < terminal.cols,
              let line = KeyboardSelectionGeometry.line(atBufferRow: position.row, in: terminal),
              line.getWidth(index: position.col) > 0 else {
            return false
        }
        let character = terminal.getCharacter(for: line[position.col])
        return character.isLetter || character.isNumber || character == "_"
    }

    private func clampedShadeKeyboardPosition(_ position: Position, lastRow: Int) -> Position {
        Position(
            col: min(max(position.col, 0), terminal.cols),
            row: clampedShadeKeyboardRow(position.row, lastRow: lastRow)
        )
    }

    private func clampedShadeKeyboardRow(_ row: Int, lastRow: Int) -> Int {
        min(max(row, 0), lastRow)
    }
}

private enum KeyboardSelectionGeometry {
    static func lastBufferRow(in terminal: Terminal) -> Int? {
        terminal.buffer.lines.count > 0 ? terminal.buffer.lines.count - 1 : nil
    }

    static func line(atBufferRow row: Int, in terminal: Terminal) -> BufferLine? {
        guard row >= 0, row < terminal.buffer.lines.count else { return nil }
        return terminal.buffer.lines[row]
    }

    static func cursorBufferPosition(in terminal: Terminal) -> Position? {
        guard let lastRow = lastBufferRow(in: terminal) else { return nil }
        return Position(col: min(max(terminal.buffer.x, 0), terminal.cols),
                        row: min(max(terminal.buffer.yBase + terminal.buffer.y, 0), lastRow))
    }
}
#endif
