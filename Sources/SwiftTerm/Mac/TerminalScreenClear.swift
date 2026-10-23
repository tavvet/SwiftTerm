#if os(macOS)
import Foundation

@MainActor
extension TerminalView {
    /// Clears previous visible output without feeding parser bytes or sending
    /// PTY input. Preserves the live cursor and the complete logical input.
    @discardableResult
    public func clearPreviousOutput(preservePrompt: Bool = true) -> Bool {
        let changed = withTerminal { terminal -> Bool in
            guard !terminal.isCurrentBufferAlternate else { return false }
            let buffer = terminal.buffer
            let screenTop = buffer.yBase
            let cursorRow = screenTop + buffer.y
            var firstPreservedRow = cursorRow
            while firstPreservedRow > screenTop,
                  buffer.lines[firstPreservedRow].isWrapped {
                firstPreservedRow -= 1
            }
            if preservePrompt, let prompt = terminal.activeSemanticPromptOrigin,
               prompt.row <= cursorRow {
                firstPreservedRow = max(screenTop, min(firstPreservedRow, prompt.row))
            }
            guard screenTop < firstPreservedRow else { return false }
            let blank = BufferLine(cols: terminal.cols)
            for row in screenTop..<firstPreservedRow {
                buffer.lines[row].copyFrom(line: blank)
            }
            selection.selectNone()
            terminal.updateFullScreen()
            return true
        }
        if changed { frameDriver.markDirty() }
        return changed
    }
}
#endif
