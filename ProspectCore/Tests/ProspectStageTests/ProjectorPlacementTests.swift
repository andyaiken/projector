import CoreGraphics
import ProspectCore
import Testing
@testable import ProspectStage

private let laptop = DisplayInfo(
    identity: DisplayIdentity(uuid: "LAPTOP", name: "Built-in Retina Display", vendor: 1552, model: 41036),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
private let epson = DisplayInfo(
    identity: DisplayIdentity(uuid: "EPSON-1", name: "EPSON PJ", vendor: 19_539, model: 1),
    frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), isMain: false)
private let monitor = DisplayInfo(
    identity: DisplayIdentity(uuid: "LG-1", name: "LG UltraFine", vendor: 7789, model: 2),
    frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), isMain: false)

@Suite("Projector placement")
struct ProjectorPlacementTests {
    @Test("Opens full-screen on the display the show names")
    func savedDisplay() {
        let state = ProjectorState.opening(saved: epson.identity, displays: [laptop, monitor, epson], console: laptop.identity)
        #expect(state == .fullScreen(epson))
    }

    @Test("A named display found again after replugging, by its UUID")
    func replugged() {
        var moved = epson
        moved.frame.origin.x = -1920
        moved.identity.name = "EPSON PJ (2)"
        #expect(ProjectorState.opening(saved: epson.identity, displays: [laptop, moved], console: laptop.identity) == .fullScreen(moved))
    }

    @Test("With nothing named, the first display that isn't the console's")
    func firstOtherDisplay() {
        #expect(ProjectorState.opening(saved: nil, displays: [laptop, epson], console: laptop.identity) == .fullScreen(epson))
    }

    @Test("Never full-screen over the console")
    func notOverTheConsole() {
        #expect(ProjectorState.opening(saved: nil, displays: [laptop], console: laptop.identity) == .windowed(.noSecondDisplay))
        #expect(ProjectorState.opening(saved: laptop.identity, displays: [laptop, epson], console: laptop.identity)
                == .windowed(.displayMissing(laptop.identity)))
    }

    @Test("A named display that's missing opens in a window, not on another display")
    func missingDisplay() {
        let state = ProjectorState.opening(saved: epson.identity, displays: [laptop, monitor], console: laptop.identity)
        #expect(state == .windowed(.displayMissing(epson.identity)))
        #expect(state.warning?.contains("EPSON PJ") == true)
    }

    @Test("A knocked cable leaves the projector waiting, hidden, and it comes back")
    func disconnectAndReturn() {
        let live = ProjectorState.fullScreen(epson)
        let gone = live.afterDisplaysChanged([laptop], console: laptop.identity)
        #expect(gone == .waiting(for: epson.identity))
        #expect(gone.isOpen)
        #expect(gone.lamp == "Projector display disconnected")
        #expect(gone.warning?.hasPrefix("The projector display, EPSON PJ, has disconnected. Carry on") == true)
        // Something else connecting doesn't take it.
        #expect(gone.afterDisplaysChanged([laptop, monitor], console: laptop.identity) == gone)
        #expect(gone.afterDisplaysChanged([laptop, epson], console: laptop.identity) == .fullScreen(epson))
    }

    @Test("A missing display that arrives takes the projector full-screen")
    func missingThenArrives() {
        let windowed = ProjectorState.windowed(.displayMissing(epson.identity))
        #expect(windowed.afterDisplaysChanged([laptop, epson], console: laptop.identity) == .fullScreen(epson))
        let alone = ProjectorState.windowed(.noSecondDisplay)
        #expect(alone.afterDisplaysChanged([laptop, epson], console: laptop.identity) == alone,
                "with nothing named, a new display is chosen by the operator")
    }

    @Test("A display rearranged in place updates the window's frame")
    func rearranged() {
        var moved = epson
        moved.frame.origin = CGPoint(x: 0, y: 982)
        #expect(ProjectorState.fullScreen(epson).afterDisplaysChanged([laptop, moved], console: laptop.identity) == .fullScreen(moved))
    }

    @Test("By preference, a missing display's place is taken by another, until it returns")
    func standIn() {
        let state = ProjectorState.opening(saved: epson.identity, displays: [laptop, monitor], console: laptop.identity,
                                           whenMissing: .anotherDisplay)
        #expect(state == .standIn(monitor, for: epson.identity))
        #expect(state.display == monitor)
        #expect(state.lamp == "Projector live on LG UltraFine, standing in")
        #expect(state.warning?.contains("EPSON PJ") == true && state.warning?.contains("LG UltraFine") == true)
        #expect(state.afterDisplaysChanged([laptop, monitor, epson], console: laptop.identity) == .fullScreen(epson),
                "the show's own display takes over when it is connected")
        #expect(state.afterDisplaysChanged([laptop], console: laptop.identity) == .waiting(for: epson.identity),
                "losing the stand-in leaves it waiting for the show's display")
        #expect(ProjectorState.opening(saved: epson.identity, displays: [laptop], console: laptop.identity, whenMissing: .anotherDisplay)
                == .windowed(.displayMissing(epson.identity)), "with nothing else connected, a window")
        #expect(ProjectorState.opening(saved: epson.identity, displays: [laptop, monitor], console: laptop.identity)
                == .windowed(.displayMissing(epson.identity)), "a window by default")
    }

    @Test("Warns when the projector is the main display")
    func mainDisplayWarning() {
        var main = epson
        main.isMain = true
        #expect(ProjectorState.fullScreen(main).warning?.contains("main display") == true)
        #expect(ProjectorState.fullScreen(epson).warning == nil)
        #expect(ProjectorState.fullScreen(epson).lamp == "Projector live on EPSON PJ")
    }
}
