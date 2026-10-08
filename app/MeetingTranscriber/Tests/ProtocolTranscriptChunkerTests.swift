@testable import MeetingTranscriber
import XCTest

final class ProtocolTranscriptChunkerTests: XCTestCase {
    func testNeedsChunkingUsesCharacterLimit() {
        let short = String(repeating: "a", count: ProtocolTranscriptChunker.directCharacterLimit)
        let long = short + "x"
        XCTAssertFalse(ProtocolTranscriptChunker.needsChunking(short))
        XCTAssertTrue(ProtocolTranscriptChunker.needsChunking(long))
    }

    func testChunksAlongNewlines() {
        let block = String(repeating: "line\n", count: 20)
        let chunks = ProtocolTranscriptChunker.chunks(block, maxCharacters: 30)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 30 })
        XCTAssertTrue(chunks.joined().contains("line"))
    }

    func testHardSplitsOversizedLine() {
        let line = String(repeating: "x", count: 50)
        let chunks = ProtocolTranscriptChunker.chunks(line, maxCharacters: 20)
        XCTAssertEqual(chunks, [
            String(repeating: "x", count: 20),
            String(repeating: "x", count: 20),
            String(repeating: "x", count: 10),
        ])
    }

    func testShortTranscriptIsASingleChunk() {
        XCTAssertEqual(ProtocolTranscriptChunker.chunks("hello"), ["hello"])
    }
}
