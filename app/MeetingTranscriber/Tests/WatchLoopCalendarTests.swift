@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopCalendarTests: XCTestCase {
    private func makeIsolatedQueue() throws -> PipelineQueue {
        let tmp = try makeTempDirectory(prefix: "watchLoopCalQ")
        return PipelineQueue(logDir: tmp, snapshotWriter: { _, _ in }) // swiftlint:disable:this trailing_closure
    }

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
        let queue = try makeIsolatedQueue()
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
            pipelineQueue: queue,
            calendarLookup: { _ in event }, // swiftlint:disable:this trailing_closure
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Jane Doe")
        XCTAssertEqual(loop.recordingTitle, "Jane Doe")
        XCTAssertEqual(loop.recordingAttendees, attendees)
        loop.stopManualRecording()
        XCTAssertEqual(queue.jobs.first?.participants, ["Jane Doe"])
        XCTAssertEqual(loop.recordingAttendees, [])
    }

    func testAutoStartPutsCalendarAttendeesOnTheJob() async throws {
        let queue = try makeIsolatedQueue()
        let attendees = [
            CalendarAttendee(email: "me@corp.com", displayName: "Mitko", isSelf: true, status: .accepted),
            CalendarAttendee(email: "jane@corp.com", displayName: "Jane Doe", status: .accepted),
            CalendarAttendee(email: "raw@corp.com", displayName: "raw@corp.com", status: .accepted),
        ]
        let event = CalendarEvent(
            id: "g1",
            title: "Sprint Planning",
            start: Date().addingTimeInterval(-60),
            end: Date().addingTimeInterval(3600),
            source: .google,
            attendees: attendees,
        )
        let recorder = makeMockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix_auto_attendees.wav")
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            calendarLookup: { _ in event }, // swiftlint:disable:this trailing_closure
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.handleMeeting(DetectedMeeting(
            pattern: .zoom,
            windowTitle: "Zoom Meeting",
            ownerName: "zoom.us",
            windowPID: 1234,
        ))
        let participants = try XCTUnwrap(queue.jobs.first?.participants)
        XCTAssertEqual(participants, ["Jane Doe", "Raw"])
        XCTAssertFalse(participants.contains { $0.contains("@") })
    }

    func testAutoStartRecordOnlySidecarPersistsCalendarParticipants() async throws {
        let queue = try makeIsolatedQueue()
        let tmp = try makeTempDirectory(prefix: "calAttendeeRO")
        let mixURL = tmp.appendingPathComponent("20260503_120000_mix.wav")
        try Data().write(to: mixURL)
        let destDir = tmp.appendingPathComponent("dest", isDirectory: true)
        let attendees = [
            CalendarAttendee(email: "jane@corp.com", displayName: "Jane Doe", status: .accepted),
            CalendarAttendee(email: "raw@corp.com", displayName: "raw@corp.com", status: .accepted),
        ]
        let event = CalendarEvent(
            id: "g1",
            title: "Sprint Planning",
            start: Date().addingTimeInterval(-60),
            end: Date().addingTimeInterval(3600),
            source: .apple,
            attendees: attendees,
        )
        let recorder = makeMockRecorder()
        recorder.mixPath = mixURL
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(destDir) },
            calendarLookup: { _ in event },
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.handleMeeting(DetectedMeeting(
            pattern: .zoom,
            windowTitle: "Zoom Meeting",
            ownerName: "zoom.us",
            windowPID: 1234,
        ))
        XCTAssertTrue(queue.jobs.isEmpty)
        let sidecarURL = destDir.appendingPathComponent("20260503_120000_meta.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(RecordingSidecar.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.participants, ["Jane Doe", "Raw"])
        XCTAssertFalse(sidecar.participants.contains { $0.contains("@") })
        let raw = try XCTUnwrap(String(data: Data(contentsOf: sidecarURL), encoding: .utf8))
        XCTAssertFalse(raw.contains("@corp.com"))
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
