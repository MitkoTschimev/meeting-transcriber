import AppKit
import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Calendar")

/// Owns Apple + Google calendar connections and the merged upcoming agenda.
/// Additive: watch/record keep working with both providers off.
@Observable
@MainActor
final class CalendarController {
    private(set) var upcoming: [CalendarEvent] = []
    /// Untrimmed active-window events used for live title enrichment. `upcoming`
    /// is capped at 12 for the agenda UI; all-day rows must not hide the meeting
    /// that is happening now.
    private var overlapEvents: [CalendarEvent] = []
    private(set) var appleStatus: CalendarAccessStatus
    private(set) var googleEmail: String?
    private(set) var lastError: String?
    private(set) var isConnectingGoogle = false
    private(set) var isRefreshing = false

    let settings: AppSettings
    let tokenStore: CalendarTokenStore
    private let apple: any AppleCalendarAccessing
    private let googleAPI: any GoogleCalendarFetching
    private let oauth: any GoogleOAuthPerforming
    private let nowProvider: () -> Date
    private var refreshTask: Task<Void, Never>?
    /// Last successful Google fetch. Transient errors keep this slice so a
    /// live meeting title is not blanked until the next good poll. Cleared on
    /// auth failure and disconnect.
    private var lastGoogleEvents: [CalendarEvent] = []
    /// Bumped on disconnect and connect so an in-flight refresh that already
    /// passed the enabled/token check cannot write Google events or tokens
    /// back after the session changes.
    private var refreshGeneration = 0
    /// Set when `refresh()` is entered while another pass is in flight so
    /// Connect is not stuck behind an early-return until the next poll.
    private var refreshAgain = false

    var googleConnected: Bool {
        tokenStore.hasToken
    }

    init(
        settings: AppSettings,
        tokenStore: CalendarTokenStore = CalendarTokenStore(),
        apple: any AppleCalendarAccessing = EventKitAppleCalendarAccess(),
        googleAPI: any GoogleCalendarFetching = GoogleCalendarAPI(),
        oauth: (any GoogleOAuthPerforming)? = nil,
        now: @escaping () -> Date = Date.init,
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.apple = apple
        self.googleAPI = googleAPI
        self.oauth = oauth ?? GoogleOAuthClient { url in
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
        nowProvider = now
        appleStatus = apple.authorizationStatus()
        googleEmail = nil
    }

    func eventOverlapping(at date: Date) -> CalendarEvent? {
        CalendarTitlePolicy.overlappingEvent(
            in: overlapEvents,
            at: date,
            userEmails: connectedAccountEmails,
        )?
            .markingCurrentUser(emails: connectedAccountEmails)
    }

    /// Google token email plus any in-memory calendar owner emails. Used to
    /// mark the current user when EventKit/`self` did not.
    private var connectedAccountEmails: Set<String> {
        var emails: Set<String> = []
        if let googleEmail {
            let trimmed = googleEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.contains("@") { emails.insert(trimmed) }
        }
        return emails
    }

    func appleToggled(_ enabled: Bool) {
        if enabled {
            Task { await requestAppleAccess() }
        } else {
            lastError = nil
            Task { await refresh() }
        }
    }

    func requestAppleAccess() async {
        lastError = nil
        let granted = await apple.requestAccess()
        appleStatus = apple.authorizationStatus()
        if !granted {
            settings.appleCalendarEnabled = false
            lastError = "Calendar access was not granted. Enable it in System Settings → Privacy & Security → Calendars."
        }
        await refresh()
    }

    func connectGoogle() async {
        guard !isConnectingGoogle else { return }
        isConnectingGoogle = true
        lastError = nil
        defer { isConnectingGoogle = false }
        let clientID = GoogleOAuthConfig.clientID(settingsValue: settings.googleOAuthClientID)
        do {
            var token = try await oauth.authorize(clientID: clientID)
            if let email = await googleAPI.primaryEmail(accessToken: token.accessToken) {
                token.email = email
            }
            try tokenStore.save(token)
            googleEmail = token.email
            settings.googleCalendarEnabled = true
            refreshGeneration += 1
            await refresh()
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("google_calendar_connect_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnectGoogle() async {
        refreshGeneration += 1
        let captured = tokenStore.read()
        tokenStore.delete()
        googleEmail = nil
        settings.googleCalendarEnabled = false
        lastError = nil
        applyDisconnectedAgenda()
        await refresh()
        if let captured {
            await oauth.revoke(captured)
        }
    }

    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain
    }

    private func performRefresh() async {
        let generation = refreshGeneration
        appleStatus = apple.authorizationStatus()
        if let token = tokenStore.read() {
            googleEmail = token.email
        } else {
            googleEmail = nil
        }
        let instant = nowProvider()
        let start = Calendar.current.startOfDay(for: instant)
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? instant.addingTimeInterval(48 * 3600)

        var groups: [[CalendarEvent]] = []
        if settings.appleCalendarEnabled {
            groups.append(apple.events(from: start, to: end))
        }
        if settings.googleCalendarEnabled {
            do {
                let google = try await googleEvents(from: start, to: end, generation: generation)
                if canCommitGoogle(generation: generation) {
                    lastGoogleEvents = google
                    groups.append(google)
                }
            } catch {
                lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("google_calendar_fetch_failed \(error.localizedDescription, privacy: .public)")
                if canCommitGoogle(generation: generation) {
                    groups.append(lastGoogleEvents)
                } else {
                    lastGoogleEvents = []
                }
            }
        } else {
            lastGoogleEvents = []
        }
        guard generation == refreshGeneration else { return }
        if !canCommitGoogle(generation: generation) {
            lastGoogleEvents = []
            groups = groups.map { $0.filter { $0.source != .google } }
        }
        let merged = CalendarAgenda.merge(groups).map { $0.markingCurrentUser(emails: connectedAccountEmails) }
        overlapEvents = CalendarAgenda.inWindow(merged, from: instant)
        upcoming = CalendarAgenda.upcoming(merged, from: instant)
    }

    func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stopPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func applyDisconnectedAgenda() {
        lastGoogleEvents = []
        let instant = nowProvider()
        if settings.appleCalendarEnabled {
            let start = Calendar.current.startOfDay(for: instant)
            let end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? instant.addingTimeInterval(48 * 3600)
            let appleEvents = apple.events(from: start, to: end)
                .map { $0.markingCurrentUser(emails: connectedAccountEmails) }
            overlapEvents = CalendarAgenda.inWindow(appleEvents, from: instant)
            upcoming = CalendarAgenda.upcoming(appleEvents, from: instant)
        } else {
            overlapEvents = []
            upcoming = []
        }
    }

    private func canCommitGoogle(generation: Int) -> Bool {
        generation == refreshGeneration && settings.googleCalendarEnabled && tokenStore.hasToken
    }

    /// True only for the grant this pass started with. A reconnect writes a
    /// different refresh token; an in-flight oauth.refresh must not overwrite it.
    private func belongsToCurrentSession(generation: Int, grant: String) -> Bool {
        generation == refreshGeneration
            && settings.googleCalendarEnabled
            && tokenStore.read()?.refreshToken == grant
    }

    private func googleEvents(from: Date, to: Date, generation: Int) async throws -> [CalendarEvent] {
        guard var token = tokenStore.read() else { return [] }
        let grant = token.refreshToken
        let clientID = GoogleOAuthConfig.clientID(settingsValue: settings.googleOAuthClientID)
        if token.isExpired(at: nowProvider()) {
            guard !clientID.isEmpty else {
                throw GoogleOAuthError.missingClientID
            }
            do {
                token = try await oauth.refresh(token, clientID: clientID)
                guard belongsToCurrentSession(generation: generation, grant: grant) else { return [] }
                try tokenStore.save(token)
                googleEmail = token.email
            } catch {
                if belongsToCurrentSession(generation: generation, grant: grant) {
                    handleGoogleAuthFailure(error)
                }
                throw error
            }
        }
        do {
            let events = try await googleAPI.fetchEvents(accessToken: token.accessToken, from: from, to: to)
            guard belongsToCurrentSession(generation: generation, grant: grant) else { return [] }
            return events
        } catch {
            if belongsToCurrentSession(generation: generation, grant: grant) {
                handleGoogleAuthFailure(error)
            }
            throw error
        }
    }

    private func handleGoogleAuthFailure(_ error: any Error) {
        guard let oauthError = error as? GoogleOAuthError, oauthError.isAuthFailure else { return }
        tokenStore.delete()
        googleEmail = nil
        settings.googleCalendarEnabled = false
        lastGoogleEvents = []
    }
}
