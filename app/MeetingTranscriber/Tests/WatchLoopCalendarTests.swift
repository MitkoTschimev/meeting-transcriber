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

    func testManualRecordingCapturesAttendeesEvenWhenTitleIsKept() async throws {
        let queue = PipelineQueue()
        let attendees = [
            CalendarAttendee(email: "me@corp.com", displayName: "Mitko", isSelf: true, status: .accepted),
            CalendarAttendee(email: "jane@corp.com", displayName: "Jane Doe", status: .accepted),
        ]
        let event = CalendarEvent(
            id: "g1",
            title: "Focus time",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            source: .apple,
            attendees: attendees,
        )
        let recorder = makeMockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        let loop = WatchLoop(
            recorderFactory: { recorder },
            calendarLookup: { _ in event },
            pipelineQueue: queue,
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Jane Doe")
        XCTAssertEqual(loop.recordingTitle, "Jane Doe")
        XCTAssertEqual(loop.recordingAttendees, attendees)
        loop.stopManualRecording()
        XCTAssertEqual(queue.jobs.first?.participants, ["Jane Doe"])
        XCTAssertEqual(loop.recordingAttendees, [])
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
