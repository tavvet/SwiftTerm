#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("Trusted link directory fallback")
struct LinkFallbackDirectoryTests {
    private final class LegacyDelegate: TerminalViewDelegate {
        var links: [String] = []
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            links.append(link)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @MainActor
    private final class Harness {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = LegacyDelegate()
        var alerts: [String] = []
        var openAttempts: [URL] = []
        init() { view.terminalDelegate = delegate }
        func activate(_ link: String, explicit: Bool = false,
                      response: NSApplication.ModalResponse = .alertFirstButtonReturn) {
            view.activateLink(link, params: [:], isExplicit: explicit) { [self] alert, _, completion in
                alerts.append(alert.messageText)
                completion(response)
            } open: { [self] in openAttempts.append($0) }
        }
        func waitForAlert() async {
            let deadline = ContinuousClock.now + .seconds(2)
            while alerts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            #expect(alerts.count == 1)
            #expect(openAttempts.isEmpty)
        }
        func expectFile(_ file: URL) {
            #expect(delegate.links.compactMap(URL.init(string:)).map {
                $0.resolvingSymlinksInPath().path
            } == [file.resolvingSymlinksInPath().path])
            #expect(alerts.isEmpty)
            // The legacy callback receives the checked target, not a launch.
            #expect(openAttempts.isEmpty)
        }
    }

    private struct Fixture {
        let directory: URL
        let file: URL
        let collision: URL?
        init(collision: Bool = false, extension suffix: String = "txt") throws {
            let manager = FileManager.default
            directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "swiftterm-link-\(UUID().uuidString).\(suffix)"
            file = directory.appendingPathComponent(name)
            try Data("plain text\n".utf8).write(to: file)
            // A unique, disposable same-name app-cwd file exercises the actual
            // fallback without changing process cwd (other suites run in parallel).
            self.collision = collision ? URL(fileURLWithPath: manager.currentDirectoryPath)
                .appendingPathComponent(name) : nil
            if let collision = self.collision {
                try Data("different app-cwd file\n".utf8).write(to: collision)
            }
        }
        func remove() {
            try? FileManager.default.removeItem(at: directory)
            if let collision { try? FileManager.default.removeItem(at: collision) }
        }
    }

    @Test(arguments: [false, true])
    func absentOsc7UsesTrustedDirectoryInsteadOfAppDirectory(collision: Bool) throws {
        let fixture = try Fixture(collision: collision)
        defer { fixture.remove() }
        let harness = Harness()
        var calls = 0
        harness.view.linkFallbackDirectoryProvider = { calls += 1; return fixture.directory.path }
        harness.activate(fixture.file.lastPathComponent)
        harness.expectFile(fixture.file)
        #expect(calls == 1)
    }

    @Test func localOsc7TakesPrecedenceWithoutCallingProvider() throws {
        let fallback = try Fixture()
        defer { fallback.remove() }
        let reported = try Fixture()
        defer { reported.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = {
            Issue.record("OSC 7 must take precedence without calling the provider")
            return fallback.directory.path
        }
        harness.view.feed(text: "\u{1b}]7;file://localhost\(reported.directory.path)\u{07}")
        harness.activate(reported.file.lastPathComponent)
        harness.expectFile(reported.file)
    }

    @Test(arguments: [false, true])
    func remoteOsc7BlocksPathsEvenWithAppCollision(collision: Bool) async throws {
        let fixture = try Fixture(collision: collision)
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = {
            Issue.record("Remote OSC 7 must not consult the local fallback")
            return fixture.directory.path
        }
        harness.view.feed(text: "\u{1b}]7;file://remote.example.invalid\(fixture.directory.path)\u{07}")
        harness.activate(fixture.file.lastPathComponent)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Link blocked"])
        #expect(harness.delegate.links.isEmpty)
    }

    @Test func disabledShellResolutionNeverCallsProvider() throws {
        let fixture = try Fixture(collision: true)
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.resolvesLinksAgainstShellDirectory = false
        harness.view.linkFallbackDirectoryProvider = {
            Issue.record("Disabled shell resolution must not call the provider")
            return fixture.directory.path
        }
        harness.activate(fixture.file.lastPathComponent)
        harness.expectFile(try #require(fixture.collision))
    }

    @Test(arguments: [nil, "", "relative", "~/relative", "/tmp/unsafe\npath", "/tmp/unsafe\u{200B}path"] as [String?])
    func invalidOrNilResultBlocksAppDirectoryCollision(directory: String?) async throws {
        let fixture = try Fixture(collision: true)
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { directory }
        harness.activate(fixture.file.lastPathComponent)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Link blocked"])
        #expect(harness.delegate.links.isEmpty)
    }

    @Test(arguments: ["http://example.invalid/docs", "https://example.invalid/docs"])
    func unavailableContextStillAllowsWebLinks(link: String) {
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { nil }
        harness.activate(link)
        #expect(harness.delegate.links == [link])
        #expect(harness.alerts.isEmpty)
        #expect(harness.openAttempts.isEmpty)
    }

    @Test func unavailableContextBlocksAnAbsoluteDetectedPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { nil }
        harness.activate(fixture.file.path)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Link blocked"])
        #expect(harness.delegate.links.isEmpty)
    }

    @Test func clearingProviderRestoresUpstreamAppDirectory() throws {
        let fixture = try Fixture(collision: true)
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { fixture.directory.path }
        harness.activate(fixture.file.lastPathComponent)
        harness.expectFile(fixture.file)
        harness.delegate.links.removeAll()
        harness.view.linkFallbackDirectoryProvider = nil
        harness.activate(fixture.file.lastPathComponent)
        harness.expectFile(try #require(fixture.collision))
    }

    @Test func unsafeFallbackFileStillBlocked() async throws {
        let fixture = try Fixture(extension: "command")
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { fixture.directory.path }
        harness.activate(fixture.file.lastPathComponent)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Link blocked"])
        #expect(harness.delegate.links.isEmpty)
    }

    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn])
    func customSchemeStillRequiresConfirmation(response: NSApplication.ModalResponse) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { fixture.directory.path }
        harness.activate("ssh://example.invalid", explicit: true, response: response)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Open link from terminal output?"])
        #expect(harness.delegate.links == (response == .alertSecondButtonReturn ? ["ssh://example.invalid"] : []))
    }

    @Test func fallbackDoesNotTurnExplicitRelativePathIntoAFileURL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = { fixture.directory.path }
        harness.activate(fixture.file.lastPathComponent, explicit: true)
        await harness.waitForAlert()
        #expect(harness.alerts == ["Link blocked"])
        #expect(harness.delegate.links.isEmpty)
    }

    @Test func disabledOsc8DoesNotConsultFallbackOrDispatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = Harness()
        harness.view.linkFallbackDirectoryProvider = {
            Issue.record("Disabled OSC 8 must not consult fallback")
            return fixture.directory.path
        }
        harness.view.enableOsc8Hyperlinks = false
        harness.activate(fixture.file.absoluteString, explicit: true)
        #expect(harness.delegate.links.isEmpty)
        #expect(harness.alerts.isEmpty)
        #expect(harness.openAttempts.isEmpty)
    }

    @Test func retainedRequestReadsCurrentProviderAndStopsWhenViewIsGone() throws {
        let first = try Fixture()
        defer { first.remove() }
        let second = try Fixture()
        defer { second.remove() }
        let secondFile = second.directory.appendingPathComponent(first.file.lastPathComponent)
        try Data("second directory\n".utf8).write(to: secondFile)
        let state = ProviderState(directory: first.directory.path)
        var opened: [URL] = []
        var request: TerminalLinkRequest?
        // AppKit may autorelease temporary owners during view setup. Drain
        // that scope before asserting the request does not retain its view.
        let viewIsAlive = autoreleasepool {
            let view = LocalProcessTerminalView(frame: .zero)
            let delegate = RetainingDelegate()
            view.terminalDelegate = delegate
            view.linkFallbackDirectoryProvider = { state.calls += 1; return state.directory }
            view.activateLink(first.file.lastPathComponent, params: [:], isExplicit: false) { _, _, _ in
                Issue.record("Plain files must not prompt")
            } open: { opened.append($0) }
            #expect(state.calls == 0)
            state.directory = second.directory.path
            request = delegate.request
            request?.openDefault()
            #expect(state.calls == 1)
            #expect(opened.map { $0.resolvingSymlinksInPath().path } == [secondFile.resolvingSymlinksInPath().path])
            return { [weak view] in view != nil }
        }
        #expect(!viewIsAlive())
        request?.openDefault()
        #expect(state.calls == 1)
        #expect(opened.count == 1)
    }

    @MainActor
    private final class ProviderState {
        var directory: String?
        var calls = 0
        init(directory: String?) { self.directory = directory }
    }

    private final class RetainingDelegate: TerminalViewDelegate {
        var request: TerminalLinkRequest?
        func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) { self.request = request }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
