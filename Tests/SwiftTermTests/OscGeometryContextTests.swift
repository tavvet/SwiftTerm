import Dispatch
import Testing
@testable import SwiftTerm

@Suite("OSC geometry context")
struct OscGeometryContextTests {
    @Test func marksKeepTheirRowsAndBufferAcrossOneBatch() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 2)
        let events = Locked<[TerminalOscEvent]>([])
        let delivered = DispatchSemaphore(value: 0)
        let observation = terminal.observeOscEvents { event in
            events.withLock { $0.append(event) }
            delivered.signal()
        }
        terminal.terminalLock.withLock {
            terminal.feed(text: "one\u{1b}]133;A\u{7}two\r\n\u{1b}]133;D;0\u{7}\u{1b}[?1049h\u{1b}]133;C\u{7}")
        }
        for _ in 0..<3 { #expect(delivered.wait(timeout: .now() + 2) == .success) }
        let captured = events.withLock { $0 }
        #expect(captured.map(\.context?.bufferCursor.row) == [1, 2, 1])
        #expect(captured.map(\.context?.isAlternateBuffer) == [false, false, true])
        #expect(captured[0].cursor == Position(col: 3, row: 0))
        #expect(captured.allSatisfy { $0.context?.dimensions.cols == 12 })
        withExtendedLifetime(observation) {}
    }

    @Test func scrollInvariantRowSurvivesTrimmingAndScrolledViewport() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 2)
        terminal.changeScrollback(2)
        terminal.feed(text: String(repeating: "line\r\n", count: 12))
        terminal.buffer.yDisp = 0
        let events = Locked<[TerminalOscEvent]>([])
        let delivered = DispatchSemaphore(value: 0)
        let observation = terminal.observeOscEvents { event in
            events.withLock { $0.append(event) }; delivered.signal()
        }
        let expected = terminal.buffer.linesTop + terminal.buffer.yBase + terminal.buffer.y
        terminal.feed(text: "\u{1b}]133;D;0\u{7}")
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        let context = try #require(events.withLock { $0.first?.context })
        #expect(context.bufferCursor.row == expected)
        #expect(context.firstRetainedRow > 0)
        withExtendedLifetime(observation) {}
    }

    @Test func widthRoundTripInvalidatesEarlierGeometry() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 3)
        let initial = terminal.inputStateSnapshot().geometryGeneration
        terminal.resize(cols: 6, rows: 3)
        terminal.resize(cols: 12, rows: 3)
        #expect(terminal.inputStateSnapshot().geometryGeneration > initial)
    }

    #if os(macOS)
    @MainActor
    @Test func localClearInvalidatesCopiedCoordinates() throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 20, rows: 4))
        let events = Locked<[TerminalOscEvent]>([])
        let delivered = DispatchSemaphore(value: 0)
        let observation = view.observeOscEvents { event in
            events.withLock { $0.append(event) }; delivered.signal()
        }
        view.feed(text: "old\r\n\u{1b}]133;A\u{7}$ pending")
        #expect(view.clearPreviousOutput())
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        let event = try #require(events.withLock { $0.first })
        let current = try #require(view.terminalInputStateSnapshot())
        #expect(try #require(event.context).geometryGeneration < current.geometryGeneration)
        withExtendedLifetime(observation) {}
    }
    #endif
}
