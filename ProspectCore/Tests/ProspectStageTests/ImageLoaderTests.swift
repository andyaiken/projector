import Testing
@testable import ProspectStage

@Suite("Image cache")
@MainActor
struct ImageLoaderTests {
    func load(_ loader: ImageLoader, _ label: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loader.load(.label(label), maxPixels: 1024) { _ in done.resume() }
        }
    }

    func isCached(_ loader: ImageLoader, _ label: String) -> Bool {
        loader.cached(.label(label), maxPixels: 1024) != nil
    }

    @Test("Keeps within its budget, dropping the least recently used first")
    func evictsLeastRecentlyUsed() async {
        // A 1024 x 576 picture takes about 2.4 MB: room for two.
        let loader = ImageLoader(budget: 5_000_000)
        await load(loader, "A")
        await load(loader, "B")
        #expect(isCached(loader, "A"), "A is now the more recently used")
        await load(loader, "C")
        #expect(loader.cachedCount == 2)
        #expect(loader.cachedBytes <= loader.budget)
        #expect(isCached(loader, "A") && isCached(loader, "C"))
        #expect(!isCached(loader, "B"), "B went first")
    }

    @Test("Keeps the newest picture even when it alone is over budget")
    func keepsTheNewest() async {
        let loader = ImageLoader(budget: 1000)
        await load(loader, "A")
        await load(loader, "B")
        #expect(loader.cachedCount == 1 && isCached(loader, "B"))
    }

    @Test("The default budget is 512 MB")
    func defaultBudget() {
        #expect(ImageLoader().budget == 512 * 1024 * 1024)
    }
}
