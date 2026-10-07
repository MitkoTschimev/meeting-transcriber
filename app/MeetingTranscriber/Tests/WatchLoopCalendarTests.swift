@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopCalendarTests: XCTestCase {
    func testManualRecordingUsesCalendarTitleWhenDetectedTitleIsGeneric() async throws {
        let start = Date()
        let event = CalendarEvent(
            id: "g1",
            title: "Sprint Planning",
            start: start.addingTimeInterval(-60),
            end: start.addingTimeInterval(3600),
            source: .google,
        )
        let recorder = makeMockRecorder()
        let loop = WatchLoop(
            recorderFactory: { recorder },
            calendarLookup: { _ in event },
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Zoom Meeting")
        defer { loop.stop() }
        XCTAssertEqual(loop.recordingTitle, "Sprint Planning")
        XCTAssertEqual(loop.manualRecordingInfo?.title, "Sprint Planning")
    }

    func testManualRecordingKeepsSpecificTitle() async throws {
        let event = CalendarEvent(
            id: "g1",
            title: "Focus time",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            source: .apple,
        )
        let recorder = makeMockRecorder()
        let loop = WatchLoop(
            recorderFactory: { recorder },
            calendarLookup: { _ in event },
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Jane Doe")
        defer { loop.stop() }
        XCTAssertEqual(loop.recordingTitle, "Jane Doe")
        XCTAssertEqual(loop.manualRecordingInfo?.title, "Jane Doe")
    }
}
