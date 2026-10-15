import Foundation
import Testing
@testable import ProspectCore

@Suite("Continue in the model")
struct ContinueModelTests {
    @Test("show.json keeps Continue plainly: absent, or seconds after firing or after finishing")
    func coding() throws {
        func encoded(_ mode: ContinueMode) throws -> [String: Double]? {
            let cue = Cue(number: "1", continueMode: mode, content: .blank(BlankContent()))
            let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(cue)) as! [String: Any]
            return json["continue"] as? [String: Double]
        }
        #expect(try encoded(.whenCued) == nil)
        #expect(try encoded(.whenFinished) == ["finished": 0])
        #expect(try encoded(.whenFinished(waitMs: 2000)) == ["finished": 2])
        #expect(try encoded(.after(ms: 2500)) == ["after": 2.5])
        for mode in [ContinueMode.whenCued, .whenFinished, .whenFinished(waitMs: 1500), .after(ms: 2500), .after(ms: 0)] {
            let cue = Cue(number: "1", continueMode: mode, content: .blank(BlankContent()))
            #expect(try JSONDecoder().decode(Cue.self, from: try JSONEncoder().encode(cue)).continueMode == mode)
        }
        let long = try JSONDecoder().decode(Cue.self, from: Data(#"{ "kind": "blank", "continue": { "finished": 99999 } }"#.utf8))
        #expect(long.continueMode == .whenFinished(waitMs: ContinueMode.longest), "an hour at most")
        // The earlier shorthand still reads.
        let bare = try JSONDecoder().decode(Cue.self, from: Data(#"{ "kind": "blank", "continue": 3 }"#.utf8))
        let word = try JSONDecoder().decode(Cue.self, from: Data(#"{ "kind": "title", "continue": "finished" }"#.utf8))
        #expect(bare.continueMode == .after(ms: 3000) && word.continueMode == .whenFinished)
    }

    @Test("An older show's follows become Continue on the cue before")
    func migratesFollows() throws {
        let json = #"""
        { "cues": [
            { "num": "1", "kind": "title", "text": "A", "follows": true },
            { "num": "2", "kind": "title", "text": "B", "follows": true },
            { "num": "3", "kind": "blank", "text": "BLANK" },
            { "num": "4", "kind": "image", "text": "C", "follows": true },
            { "num": "5", "kind": "video", "text": "D", "atEnd": "loop" },
            { "num": "6", "kind": "title", "text": "E", "follows": true }
        ] }
        """#
        let show = try JSONDecoder().decode(Show.self, from: Data(json.utf8))
        #expect(show.cues.map(\.continueMode) == [.whenFinished, .whenCued, .after(ms: 0), .whenCued, .whenFinished, .whenCued])
        // A follow on the first cue had nothing before it, and is dropped.
    }

    @Test("When finished means something only for a cue that takes time")
    func finishes() {
        #expect(Cue(content: .title(TitleContent())).finishes)
        #expect(Cue(content: .image(ImageContent())).finishes)
        #expect(Cue(content: .video(VideoContent(atEnd: .black))).finishes)
        #expect(!Cue(content: .video(VideoContent(atEnd: .loop))).finishes)
        #expect(!Cue(content: .blank(BlankContent())).finishes)
    }

    @Test("How a Continue reads on the printed sheet")
    func summaries() {
        #expect(ContinueMode.whenFinished.summary == "when finished")
        #expect(ContinueMode.after(ms: 5000).summary == "after 5 s")
        #expect(ContinueMode.after(ms: 2500).summary == "after 2.5 s")
        #expect(ContinueMode.after(ms: 0).summary == "at once")
        #expect(ContinueMode.whenFinished(waitMs: 2000).summary == "2 s after it finishes")
        #expect(ContinueMode.whenFinished.isImmediate && ContinueMode.after(ms: 0).isImmediate)
        #expect(!ContinueMode.whenFinished(waitMs: 500).isImmediate && !ContinueMode.after(ms: 500).isImmediate)
    }
}
