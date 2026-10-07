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
        CalendarTitlePolicy.overlappingEvent(in: overlapEvents, at: date)
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
            await refresh()
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("google_calendar_connect_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnectGoogle() async {
        if let token = tokenStore.read() {
            await oauth.revoke(token)
        }
        tokenStore.delete()
        googleEmail = nil
        settings.googleCalendarEnabled = false
        lastError = nil
        await refresh()
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
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
                let google = try await googleEvents(from: start, to: end)
                groups.append(google)
            } catch {
                lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("google_calendar_fetch_failed \(error.localizedDescription, privacy: .public)")
            }
        }
        let merged = CalendarAgenda.merge(groups)
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

    private func googleEvents(from: Date, to: Date) async throws -> [CalendarEvent] {
        guard var token = tokenStore.read() else { return [] }
        let clientID = GoogleOAuthConfig.clientID(settingsValue: settings.googleOAuthClientID)
        if token.isExpired(at: nowProvider()) {
            guard !clientID.isEmpty else {
                throw GoogleOAuthError.missingClientID
            }
            do {
                token = try await oauth.refresh(token, clientID: clientID)
                try tokenStore.save(token)
                googleEmail = token.email
            } catch {
                handleGoogleAuthFailure(error)
                throw error
            }
        }
        do {
            return try await googleAPI.fetchEvents(accessToken: token.accessToken, from: from, to: to)
        } catch {
            handleGoogleAuthFailure(error)
            throw error
        }
    }

    private func handleGoogleAuthFailure(_ error: any Error) {
        guard let oauthError = error as? GoogleOAuthError, oauthError.isAuthFailure else { return }
        tokenStore.delete()
        googleEmail = nil
        settings.googleCalendarEnabled = false
    }
}
