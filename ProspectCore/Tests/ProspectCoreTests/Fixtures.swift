import Foundation
import Testing

// Known-good outputs for the model: cipher text, reveal timing, tile
// schedules and numbering, recorded from seeded runs.
// A change that alters any of them alters what the audience sees, so it
// should be deliberate.

enum Fixtures {
    struct Missing: Error { let name: String }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}

// MARK: - Shapes

struct CipherFixture: Decodable {
    struct Encrypt: Decodable { let plain, key, cipher: String }
    struct Warmth: Decodable { let t: Double; let colour: String }
    struct Chi: Decodable { let counts: [Int]; let chi: Double?; let text: String? }
    struct Fixed: Decodable { let value: Double; let text: String }

    let ring: String
    let english: [Double]
    let ghostHeights: [Double]
    let encrypt: [Encrypt]
    let warmth: [Warmth]
    let chiSquared: [Chi]
    let toFixed: [Fixed]
}

struct RandomFixture: Decodable {
    struct Sequence: Decodable { let seed: UInt32; let values: [Double] }
    let lcg: [Sequence]
}

struct PlanFixture: Decodable, Sendable {
    struct Char: Decodable, Sendable {
        let p, c: String
        let moves: Bool
        let steps, pad, start: Int
    }
    let chars: [Char]
    let duration: Int
    let keyLen: Int
}

struct PlansFixture: Decodable {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let text, key: String
        let stagger: Int
        let seed: UInt32
        let plan: PlanFixture
        var testDescription: String { "\"\(text)\" seed \(seed)" }
    }
    let plans: [Case]
}

/// The settings a recorded run used, under the names it recorded them with.
struct RecordedSettings: Decodable, Sendable {
    let speed, stagger, hold, cols, flipMs: Int
    let hist, sub: Bool
    let order: String
}

struct TitleRunsFixture: Decodable {
    struct Run: Decodable, Sendable, CustomTestStringConvertible {
        struct CueText: Decodable, Sendable { let text, sub, key: String }
        struct Frame: Decodable, Sendable {
            let f: Int
            let done: Bool
            let title: String
            let titleColours: [String]
            let sub: String
            let subColours: [String]
            let bars: [Double]
            let solved, keyLength, chi: String
        }
        let name: String
        let cue: CueText
        let settings: RecordedSettings
        let seed: UInt32
        let titlePlan, subPlan: PlanFixture
        let histMax: Int
        let subShown, histogramShown: Bool
        let frames: [Frame]
        var testDescription: String { name }
    }
    let runs: [Run]
}

struct TilesFixture: Decodable {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let width, height: Double
        let settings: RecordedSettings
        let seed: UInt32
        let cols, rows: Int
        let starts: [Int]
        let lastStart, settledAt: Int
        let pixels: [UInt8]
        let backColours: [String]
        var testDescription: String { name }
    }
    let tiles: [Case]
}

struct NumberingFixture: Decodable {
    struct Lookup: Decodable {
        struct Case: Decodable { let query: String; let index: Int }
        let numbers: [String]
        let cases: [Case]
    }
    let lookup: Lookup
}
