import Foundation
import Testing
@testable import ProspectCore

@Suite("Transitions in the model")
struct TransitionModelTests {
    @Test("Every cue fades through black for half a second unless told otherwise")
    func defaults() {
        let cue = Cue(content: .blank(BlankContent()))
        #expect(cue.transitionIn(defaults: ShowSettings()) == Transition(style: .fade, fadeMs: 500))
        var settings = ShowSettings()
        settings.transition = .snap
        #expect(cue.transitionIn(defaults: settings).style == .snap)
    }

    @Test("A cue can override the style, the fade time, or both")
    func overrides() {
        var cue = Cue(content: .blank(BlankContent()))
        cue.transition.fadeMs = 1200
        #expect(cue.transitionIn(defaults: ShowSettings()) == Transition(style: .fade, fadeMs: 1200))
        cue.transition.style = .snap
        #expect(cue.transitionIn(defaults: ShowSettings()) == Transition(style: .snap, fadeMs: 1200))
    }

    @Test("show.json keeps a cue's own transition, and nothing when it has none")
    func coding() throws {
        var cue = Cue(number: "1", content: .title(TitleContent(text: "THE LOUVRE", key: "KEY")))
        let plain = String(decoding: try JSONEncoder().encode(cue), as: UTF8.self)
        #expect(!plain.contains("transition"))
        cue.transition = TransitionOverrides(style: .snap, fadeMs: 9000)
        let back = try JSONDecoder().decode(Cue.self, from: try JSONEncoder().encode(cue))
        #expect(back.transition == TransitionOverrides(style: .snap, fadeMs: SettingRange.fadeMs.upperBound), "clamped on the way in")
    }

    @Test("A show saved before transitions existed opens with the default")
    func olderShows() throws {
        let settings = try JSONDecoder().decode(ShowSettings.self, from: Data(#"{ "clockMs": 44 }"#.utf8))
        #expect(settings.transition == .fade && settings.fadeMs == 500)
    }

    @Test("Transition and fade read and choose like the other settings")
    func settingKeys() {
        #expect(SettingKey.fade.format(.number(500)) == "0.5 s")
        #expect(SettingKey.fade.format(.number(1200)) == "1.2 s")
        #expect(SettingKey.transition.format(.style(.snap)) == "snap")
        #expect(SettingKey.transition.format(.style(.fade)) == "fade through black")
        #expect(SettingKey.transition.choice(at: 1) == .style(.snap))
        #expect(SettingKey.transition.choiceIndex(of: .style(.fade)) == 0)
        #expect(SettingKey.order.choiceIndex(of: .order(.random)) == 1)
        var cue = Cue(content: .video(VideoContent()))
        SettingKey.transition.setOverride(.style(.snap), in: &cue)
        SettingKey.fade.setOverride(.number(730), in: &cue)
        #expect(cue.transition == TransitionOverrides(style: .snap, fadeMs: 700), "fade time snaps to its step")
        #expect(SettingKey.fade.effective(for: cue, defaults: ShowSettings()) == (.number(700), true))
        SettingKey.fade.setOverride(nil, in: &cue)
        #expect(SettingKey.fade.effective(for: cue, defaults: ShowSettings()) == (.number(500), false))
    }
}
