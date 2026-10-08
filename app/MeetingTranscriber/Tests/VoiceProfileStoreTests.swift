@testable import MeetingTranscriber
import XCTest

/// Live naming writes the same on-device `speakers.json` the batch pipeline
/// and Settings → Speakers use.
@MainActor
final class VoiceProfileStoreTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        dbPath = try makeTempDirectory(prefix: "VoiceProfileStoreTests").appendingPathComponent("speakers.json")
    }

    func testEnrollCreatesAProfileTheMatcherRecognises() {
        var changes = 0
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath) { changes += 1 }

        store.enroll(VoiceEnrollment(name: "Alice", embedding: [1, 0, 0], speakingTime: 5))

        let stored = SpeakerMatcher(dbPath: dbPath).loadDB()
        XCTAssertEqual(stored.map(\.name), ["Alice"])
        XCTAssertEqual(stored.first?.centroid, [1, 0, 0])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.savedVoiceNames(), ["Alice"])
    }

    func testEnrollFoldsACorrectionIntoTheExistingProfile() throws {
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        store.enroll(VoiceEnrollment(name: "Alice", embedding: [1, 0, 0], speakingTime: 5))
        store.enroll(VoiceEnrollment(name: "Alice", embedding: [0, 1, 0], speakingTime: 5))

        let alice = try XCTUnwrap(SpeakerMatcher(dbPath: dbPath).loadDB().first)
        XCTAssertEqual(alice.centroidSampleCount, 2)
        XCTAssertEqual(alice.embeddings.count, 2)
        XCTAssertEqual(alice.useCount, 2)
    }

    func testRenameProfileRenamesRatherThanDuplicating() {
        var changes = 0
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath) { changes += 1 }
        store.enroll(VoiceEnrollment(name: "Aice", embedding: [1, 0, 0], speakingTime: 5))
        store.renameProfile(from: "Aice", to: "Bob")

        XCTAssertEqual(SpeakerMatcher(dbPath: dbPath).loadDB().map(\.name), ["Bob"])
        XCTAssertEqual(store.savedVoiceNames(), ["Bob"])
        XCTAssertEqual(changes, 2)
    }

    func testWithdrawRemovesThisMeetingsSampleFromAnExistingProfile() throws {
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        store.enroll(VoiceEnrollment(name: "Bob", embedding: [1, 0, 0], speakingTime: 5))
        let before = try XCTUnwrap(SpeakerMatcher(dbPath: dbPath).loadDB().first)

        store.enroll(VoiceEnrollment(name: "Bob", embedding: [0, 1, 0], speakingTime: 5))
        store.withdraw(VoiceEnrollment(name: "Bob", embedding: [0, 1, 0], speakingTime: 5), from: "Bob")

        let after = try XCTUnwrap(SpeakerMatcher(dbPath: dbPath).loadDB().first)
        XCTAssertEqual(after.name, "Bob")
        XCTAssertEqual(after.embeddings, before.embeddings)
        XCTAssertEqual(after.centroidSampleCount, before.centroidSampleCount)
        XCTAssertEqual(after.centroid, before.centroid)
        XCTAssertEqual(after.useCount, before.useCount)
    }

    func testPostStopCorrectionOnExistingProfileLeavesTheOriginalName() {
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        store.enroll(VoiceEnrollment(name: "Bob", embedding: [1, 0, 0], speakingTime: 5))
        XCTAssertFalse(store.enroll(VoiceEnrollment(name: "Bob", embedding: [0, 1, 0], speakingTime: 5)))
        store.withdraw(VoiceEnrollment(name: "Bob", embedding: [0, 1, 0], speakingTime: 5), from: "Bob")
        XCTAssertTrue(store.enroll(VoiceEnrollment(name: "Rob", embedding: [0, 1, 0], speakingTime: 5)))

        XCTAssertEqual(
            Set(SpeakerMatcher(dbPath: dbPath).loadDB().map(\.name)),
            ["Bob", "Rob"],
        )
    }

    func testEmptyEmbeddingIsIgnored() {
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        store.enroll(VoiceEnrollment(name: "Alice", embedding: [], speakingTime: 5))
        XCTAssertTrue(SpeakerMatcher(dbPath: dbPath).loadDB().isEmpty)
    }

    func testSavedNamesAreMostRecentFirstAndSkipSeededEntries() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        matcher.saveDB([
            StoredSpeaker(name: "Old", embeddings: [[1, 0]], lastUsed: old, useCount: 1),
            StoredSpeaker(name: "Seeded", embeddings: [[0, 1]], lastUsed: Date(), useCount: 1, isSynthetic: true),
            StoredSpeaker(name: "Recent", embeddings: [[1, 1]], lastUsed: old.addingTimeInterval(3600), useCount: 1),
        ])

        XCTAssertEqual(SpeakerDBVoiceProfileStore(dbPath: dbPath).savedVoiceNames(), ["Recent", "Old"])
    }

    func testSavedNamesCacheInvalidatesWhenTheFileIsWrittenElsewhere() {
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        XCTAssertEqual(store.savedVoiceNames(), [])

        SpeakerMatcher(dbPath: dbPath).saveDB([
            StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]], lastUsed: Date(), useCount: 1),
        ])

        XCTAssertEqual(store.savedVoiceNames(), ["Alice"])
    }
}
