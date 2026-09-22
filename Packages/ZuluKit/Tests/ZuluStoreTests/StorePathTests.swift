import Foundation
import Testing
@testable import ZuluStore

struct StorePathTests {

    /// The iOS container path contains "Application Support". A URL converted with the
    /// percent-encoding default hands SQLite "Application%20Support" and it fails to open.
    @Test func opensADatabaseInADirectoryWithASpaceInItsName() throws {
        let directory = URL.temporaryDirectory
            .appending(path: "Zulu Store Tests \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appending(path: "zulu.sqlite")
        _ = try ZuluStore(url: databaseURL)

        #expect(FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)))
    }

    @Test func inMemoryStoreNeedsNoPath() throws {
        let store = try ZuluStore(url: nil)
        #expect(try store.channels().isEmpty)
    }

    @Test func dmKeyIncludesTheViewerAndIsOrderIndependent() {
        let a = MessageRecord.dmKey(for: [7, 3], selfUserID: 1)
        let b = MessageRecord.dmKey(for: [3, 7, 1], selfUserID: 1)
        #expect(a == "1,3,7")
        #expect(a == b)
    }
}
