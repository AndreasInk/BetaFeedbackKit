import CoreGraphics
import Foundation
import OSLog
@preconcurrency import UserNotifications

private let betaFeedbackConversationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.andreasink.BetaFeedbackKit",
    category: "BetaFeedbackKitConversation"
)

/// Controls BetaFeedbackKit's screenshot-triggered notification conversation.
public enum BetaFeedbackNotificationMode: Sendable, Equatable {
    /// Keep the existing screenshot guidance and feedback sheet behavior.
    case disabled

    /// On iOS 27 or later, ask for feedback in notifications and optionally ask one
    /// follow-up question. Earlier systems keep the existing screenshot flow.
    case onScreenshot
}

/// Overrides automatic app-window capture for iOS/macOS 27 multimodal analysis.
///
/// `UIApplication.userDidTakeScreenshotNotification` does not include the screenshot.
/// Returning nil skips model clarification. Images are captured before feedback UI appears.
/// BetaFeedbackKit never persists this image or includes it in a notification or report.
public typealias BetaFeedbackScreenshotProvider = @MainActor @Sendable () -> CGImage?

enum BetaFeedbackNotificationIdentifiers {
    static let schemaVersion = 1
    static let prefix = "dev.andreasink.BetaFeedbackKit.feedback"
    static let initialTextCategory = "\(prefix).initial-text.v1"
    static let textCategory = "\(prefix).text.v2"
    static let yesNoCategory = "\(prefix).yes-no.v1"
    static let frequencyCategory = "\(prefix).frequency.v1"
    static let scopeCategory = "\(prefix).scope.v1"
    static let textAction = "\(prefix).reply-text.v1"
    static let yesAction = "\(prefix).reply-yes.v1"
    static let noAction = "\(prefix).reply-no.v1"
    static let everyTimeAction = "\(prefix).reply-every-time.v1"
    static let onceAction = "\(prefix).reply-once.v1"
    static let wholeAppAction = "\(prefix).reply-whole-app.v1"
    static let oneControlAction = "\(prefix).reply-one-control.v1"
    static let finishAction = "\(prefix).finish.v1"
    static let conversationIDKey = "betafeedbackkit_conversation_id"
    static let turnKey = "betafeedbackkit_turn"
    static let schemaKey = "betafeedbackkit_schema"
    static let sourceKey = "source"
    static let sourceValue = "BetaFeedbackKitConversation"

    static func completionRequestIdentifier(for conversationID: UUID) -> String {
        "\(prefix).\(conversationID.uuidString).completed"
    }
}

enum BetaFeedbackCompletionCopy {
    static func body(copied: Bool) -> String {
        if copied {
            "Tap the checkmark on your screenshot, choose Share Beta Feedback, then paste the copied report into the text box."
        } else {
            "Open the app to copy the report. Then tap the screenshot checkmark, choose Share Beta Feedback, and paste it into the text box."
        }
    }
}

enum BetaFeedbackConversationStatus: String, Sendable, Codable, Equatable {
    case awaitingResponse
    case processing
    case completed
}

struct BetaFeedbackConversationSnapshot: Sendable, Codable, Equatable {
    let questionID: String
    let questionTitle: String
    let metadata: [String: String]
    let developerContext: [String: String]
    let activeStates: [BetaFeedbackState]
    let diagnosticContext: BetaFeedbackDiagnosticContext
}

struct BetaFeedbackConversationRecord: Sendable, Codable, Equatable {
    /// The original feedback plus at most one answer to a generated follow-up.
    static let maximumResponseCount = 2
    /// Keeps responses from already-delivered notifications routable after upgrading.
    static let legacyMaximumRoutableResponseCount = 4

    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let snapshot: BetaFeedbackConversationSnapshot
    var status: BetaFeedbackConversationStatus
    var pendingQuestion: BetaFeedbackConversationQuestion
    var pendingRequestID: String
    var responses: [BetaFeedbackClarificationTurn]
    var analysis: BetaFeedbackClarificationAnalysis?
    var completedReport: BetaFeedbackReport?

    var expectedResponseNumber: Int { responses.count + 1 }
    var hasAtLeastOneResponse: Bool { !responses.isEmpty }
    var shouldOfferFinishAction: Bool { hasAtLeastOneResponse }
    var reachedResponseLimit: Bool { responses.count >= Self.maximumResponseCount }

    static func new(
        id: UUID = UUID(),
        date: Date = .now,
        lifetime: TimeInterval = 24 * 60 * 60,
        snapshot: BetaFeedbackConversationSnapshot
    ) -> Self {
        let question = BetaFeedbackConversationQuestion(
            text: "What feedback do you have?",
            responseStyle: .text
        )
        return Self(
            id: id,
            createdAt: date,
            expiresAt: date.addingTimeInterval(lifetime),
            snapshot: snapshot,
            status: .awaitingResponse,
            pendingQuestion: question,
            pendingRequestID: requestIdentifier(id: id, responseNumber: 1),
            responses: [],
            analysis: nil,
            completedReport: nil
        )
    }

    mutating func acceptResponse(_ response: String) -> Bool {
        guard status == .awaitingResponse,
              !reachedResponseLimit,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        responses.append(.init(question: pendingQuestion.text, response: response))
        status = .processing
        return true
    }

    mutating func awaitNextQuestion(_ question: BetaFeedbackConversationQuestion) {
        precondition(!reachedResponseLimit)
        pendingQuestion = question
        pendingRequestID = Self.requestIdentifier(id: id, responseNumber: expectedResponseNumber)
        status = .awaitingResponse
    }

    mutating func complete(with report: BetaFeedbackReport) {
        status = .completed
        completedReport = report
    }

    func analysisInput() -> FeedbackAnalysisInput? {
        guard let first = responses.first else { return nil }
        return FeedbackAnalysisInput(
            originalFeedback: first.response,
            questionID: snapshot.questionID,
            questionTitle: snapshot.questionTitle,
            metadata: snapshot.metadata,
            developerContext: snapshot.developerContext,
            activeStates: snapshot.activeStates,
            diagnosticContext: snapshot.diagnosticContext,
            clarificationTurns: Array(responses.dropFirst())
        )
    }

    static func requestIdentifier(id: UUID, responseNumber: Int) -> String {
        "\(BetaFeedbackNotificationIdentifiers.prefix).\(id.uuidString).response.\(responseNumber)"
    }
}

@MainActor
protocol BetaFeedbackConversationStoring {
    func load() -> BetaFeedbackConversationRecord?
    func save(_ record: BetaFeedbackConversationRecord)
    func clear()
}

@MainActor
final class UserDefaultsFeedbackConversationStore: BetaFeedbackConversationStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.andreasink.BetaFeedbackKit"
        self.key = "\(bundleID).BetaFeedbackKit.feedbackConversation.v1"
    }

    func load() -> BetaFeedbackConversationRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BetaFeedbackConversationRecord.self, from: data)
    }

    func save(_ record: BetaFeedbackConversationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

extension BetaContentViewModel {
    @MainActor
    func isCurrentFeedbackConversation(_ record: BetaFeedbackConversationRecord) -> Bool {
        feedbackConversationStore.load()?.id == record.id
    }

    @MainActor
    @discardableResult
    func saveFeedbackConversationIfCurrent(_ record: BetaFeedbackConversationRecord) -> Bool {
        guard isCurrentFeedbackConversation(record) else { return false }
        feedbackConversationStore.save(record)
        return true
    }

    @MainActor
    @discardableResult
    func clearFeedbackConversationIfCurrent(_ record: BetaFeedbackConversationRecord) -> Bool {
        guard isCurrentFeedbackConversation(record) else { return false }
        feedbackConversationStore.clear()
        return true
    }
}

struct BetaFeedbackNotificationEnvelope: Sendable, Equatable {
    let conversationID: UUID
    let responseNumber: Int

    init(conversationID: UUID, responseNumber: Int) {
        self.conversationID = conversationID
        self.responseNumber = responseNumber
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let source = userInfo[BetaFeedbackNotificationIdentifiers.sourceKey] as? String,
              source == BetaFeedbackNotificationIdentifiers.sourceValue,
              let schema = userInfo[BetaFeedbackNotificationIdentifiers.schemaKey] as? Int,
              schema == BetaFeedbackNotificationIdentifiers.schemaVersion,
              let idValue = userInfo[BetaFeedbackNotificationIdentifiers.conversationIDKey] as? String,
              let id = UUID(uuidString: idValue),
              let responseNumber = userInfo[BetaFeedbackNotificationIdentifiers.turnKey] as? Int,
              (1...BetaFeedbackConversationRecord.legacyMaximumRoutableResponseCount).contains(responseNumber) else {
            return nil
        }
        self.conversationID = id
        self.responseNumber = responseNumber
    }

    var userInfo: [String: Any] {
        [
            BetaFeedbackNotificationIdentifiers.sourceKey: BetaFeedbackNotificationIdentifiers.sourceValue,
            BetaFeedbackNotificationIdentifiers.schemaKey: BetaFeedbackNotificationIdentifiers.schemaVersion,
            BetaFeedbackNotificationIdentifiers.conversationIDKey: conversationID.uuidString,
            BetaFeedbackNotificationIdentifiers.turnKey: responseNumber
        ]
    }
}

#if os(iOS)
/// A Sendable snapshot of a BetaFeedbackKit notification response.
///
/// Create this synchronously inside the host's notification-center delegate before
/// hopping to another actor. This avoids carrying Apple's non-Sendable notification
/// response object across an isolation boundary.
public struct BetaFeedbackNotificationResponse: Sendable {
    let requestIdentifier: String
    let actionIdentifier: String
    let userText: String?
    let conversationID: UUID?
    let responseNumber: Int?
    let isCompletion: Bool

    public init?(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        let userInfo = content.userInfo
        guard userInfo[BetaFeedbackNotificationIdentifiers.sourceKey] as? String
                == BetaFeedbackNotificationIdentifiers.sourceValue,
              userInfo[BetaFeedbackNotificationIdentifiers.schemaKey] as? Int
                == BetaFeedbackNotificationIdentifiers.schemaVersion else {
            return nil
        }

        requestIdentifier = response.notification.request.identifier
        actionIdentifier = response.actionIdentifier
        userText = (response as? UNTextInputNotificationResponse)?.userText
        isCompletion = userInfo["betafeedbackkit_completion"] as? Bool == true

        if let envelope = BetaFeedbackNotificationEnvelope(userInfo: userInfo) {
            conversationID = envelope.conversationID
            responseNumber = envelope.responseNumber
        } else if isCompletion,
                  let idValue = userInfo[BetaFeedbackNotificationIdentifiers.conversationIDKey] as? String,
                  let id = UUID(uuidString: idValue) {
            conversationID = id
            responseNumber = nil
        } else {
            return nil
        }
    }
}

private actor BetaFeedbackNotificationCompletionGate {
    private var hasCompleted = false

    func claim() -> Bool {
        guard !hasCompleted else { return false }
        hasCompleted = true
        return true
    }
}

private final class BetaFeedbackNotificationCompletionBox: @unchecked Sendable {
    private let gate = BetaFeedbackNotificationCompletionGate()
    private let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func callOnMainActor() async {
        guard await gate.claim() else { return }
        await MainActor.run {
            completionHandler()
        }
    }
}

public extension BetaContentViewModel {
    /// Starts the iOS 27 notification conversation immediately.
    ///
    /// This is useful for a host app's debug menu or a custom screenshot route. The normal
    /// `.onScreenshot` mode calls it after presenting screenshot guidance, and the request's
    /// one-second trigger gives the tester time to read that guidance first.
    @MainActor
    @discardableResult
    func startFeedbackNotificationConversation() async -> Bool {
        guard feedbackNotificationMode == .onScreenshot,
              Self.isDebugOrTestFlight(), #available(iOS 27.0, *) else { return false }
        let generation = UUID()
        notificationStartGeneration = generation
        let screenshot = captureFeedbackScreenshot()
        return await startFeedbackNotificationConversation(capturedScreenshot: screenshot, startGeneration: generation)
    }
}

extension BetaContentViewModel {
    @MainActor
    func startFeedbackNotificationConversation(capturedScreenshot: CGImage?, startGeneration: UUID) async -> Bool {
        guard feedbackNotificationMode == .onScreenshot,
              Self.isDebugOrTestFlight() else {
            return false
        }
        guard #available(iOS 27.0, *) else { return false }

        guard await ensureFeedbackNotificationAuthorization() else {
            AnalyticsManager.logEvent("TestFlight.Feedback.ConversationUnavailable", info: [
                "reason": "notification_authorization"
            ])
            return false
        }

        guard notificationStartGeneration == startGeneration else { return false }
        await registerFeedbackNotificationCategories()
        guard notificationStartGeneration == startGeneration else { return false }
        let snapshotInput = makeFeedbackAnalysisInput(
            answer: "",
            questionID: "screenshot-feedback",
            questionTitle: "What feedback do you have?"
        )
        let snapshot = BetaFeedbackConversationSnapshot(
            questionID: snapshotInput.questionID,
            questionTitle: snapshotInput.questionTitle,
            metadata: snapshotInput.metadata,
            developerContext: snapshotInput.developerContext,
            activeStates: snapshotInput.activeStates,
            diagnosticContext: snapshotInput.diagnosticContext
        )
        if let previous = feedbackConversationStore.load() {
            let center = UNUserNotificationCenter.current()
            let previousNotificationIDs = [
                previous.pendingRequestID,
                BetaFeedbackNotificationIdentifiers.completionRequestIdentifier(for: previous.id)
            ]
            center.removePendingNotificationRequests(withIdentifiers: previousNotificationIDs)
            center.removeDeliveredNotifications(withIdentifiers: previousNotificationIDs)
        }
        let record = BetaFeedbackConversationRecord.new(snapshot: snapshot)
        feedbackConversationStore.save(record)
        latestFeedbackReport = nil
        activeConversationScreenshot = capturedScreenshot.map { (record.id, $0) }
        conversationScreenshotExpiryTask?.cancel()
        if capturedScreenshot != nil {
            let expiryDelay = max(0, record.expiresAt.timeIntervalSinceNow)
            conversationScreenshotExpiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(expiryDelay)) } catch { return }
                guard self?.activeConversationScreenshot?.id == record.id else { return }
                self?.activeConversationScreenshot = nil
            }
        }

        do {
            try await schedule(record: record, delay: BetaFeedbackNotificationTiming.initialDelay)
            guard notificationStartGeneration == startGeneration,
                  isCurrentFeedbackConversation(record) else {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: [record.pendingRequestID])
                center.removeDeliveredNotifications(withIdentifiers: [record.pendingRequestID])
                clearFeedbackConversation(ifCurrent: record)
                return false
            }
            betaFeedbackConversationLogger.info("Scheduled initial feedback notification")
            AnalyticsManager.logEvent("TestFlight.Feedback.ConversationStarted", info: [
                "source": "screenshot"
            ])
            return true
        } catch {
            guard isCurrentFeedbackConversation(record) else {
                betaFeedbackConversationLogger.notice(
                    "Superseded initial notification work with a newer conversation"
                )
                return false
            }
            clearFeedbackConversation(ifCurrent: record)
            AnalyticsManager.logEvent("TestFlight.Feedback.ConversationUnavailable", info: [
                "reason": "notification_schedule"
            ])
            return false
        }
    }

    /// Handles a response that the host app received through `UNUserNotificationCenterDelegate`.
    ///
    /// BetaFeedbackKit never takes ownership of the notification center delegate. Forward the response
    /// from the host, await this method, and then call the system completion handler promptly.
    @MainActor
    @discardableResult
    public func handleNotificationResponse(_ response: UNNotificationResponse) async -> Bool {
        guard let capturedResponse = BetaFeedbackNotificationResponse(response) else { return false }
        return await handleNotificationResponse(capturedResponse)
    }

    /// Captures and processes a BetaFeedbackKit notification response while returning promptly after
    /// durable persistence; model analysis and scheduling continue asynchronously.
    ///
    /// Call this overload directly from a nonisolated notification-center delegate. It returns
    /// `false` synchronously for notifications that do not belong to BetaFeedbackKit; in that case the
    /// host remains responsible for calling `completionHandler`.
    @discardableResult
    public nonisolated func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard let capturedResponse = BetaFeedbackNotificationResponse(response) else { return false }
        let completion = BetaFeedbackNotificationCompletionBox(completionHandler)
        Task {
            try? await Task.sleep(for: .seconds(10))
            await completion.callOnMainActor()
        }
        Task { @MainActor [weak self] in
            if let self {
                _ = await self.handleNotificationResponse(capturedResponse)
            }
            await completion.callOnMainActor()
        }
        return true
    }

    /// Handles a previously captured, Sendable BetaFeedbackKit notification response.
    ///
    /// Prefer this overload when the host delegate is nonisolated: construct the value
    /// synchronously, call the system completion handler, then forward it to BetaFeedbackKit.
    @MainActor
    @discardableResult
    public func handleNotificationResponse(
        _ response: BetaFeedbackNotificationResponse
    ) async -> Bool {

        if response.isCompletion {
            if let conversationID = response.conversationID,
               let record = feedbackConversationStore.load(),
               record.id == conversationID,
               let report = record.completedReport {
                latestFeedbackReport = report
                _ = copyFeedbackToPasteboard(report: report)
            }
            return true
        }

        guard let conversationID = response.conversationID,
              let responseNumber = response.responseNumber,
              var record = feedbackConversationStore.load(),
              record.id == conversationID else {
            return true
        }

        guard Date.now < record.expiresAt else {
            feedbackConversationStore.clear()
            activeConversationScreenshot = nil
            return true
        }

        // A previous package revision could have already scheduled another question.
        // Complete with the first clarification instead of reviving that older flow.
        if record.status != .completed, record.reachedResponseLimit {
            await completeFeedbackConversation(record, outcome: "response_limit_migrated")
            return true
        }

        guard record.status == .awaitingResponse,
              record.pendingRequestID == response.requestIdentifier,
              record.expectedResponseNumber == responseNumber else {
            return true
        }

        let reply = BetaFeedbackNotificationReply.parse(
            actionIdentifier: response.actionIdentifier,
            userText: response.userText,
            question: record.pendingQuestion
        )
        switch reply {
        case .answer(let answer):
            guard record.acceptResponse(answer) else { return true }
            feedbackConversationStore.save(record)
            betaFeedbackConversationLogger.info(
                "Persisted feedback response \(record.responses.count, privacy: .public)"
            )
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [record.pendingRequestID]
            )
            AnalyticsManager.logEvent("TestFlight.Feedback.ConversationResponse", info: [
                "responseNumber": String(record.responses.count),
                "responseStyle": responseStyleName(record.pendingQuestion.responseStyle)
            ])
            Task { @MainActor [weak self] in
                await self?.processFeedbackConversation(record)
            }
        case .finish:
            guard record.hasAtLeastOneResponse else { return true }
            await completeFeedbackConversation(record, outcome: "tester_finished")
        case .open:
            if let completed = record.completedReport {
                latestFeedbackReport = completed
                _ = copyFeedbackToPasteboard(report: completed)
            } else {
                // iOS cannot open a notification text-input action from a normal banner tap.
                // Put the pending prompt back in front of the tester and repeat the education
                // cue instead of turning that common tap into a dead end.
                do {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: [record.pendingRequestID]
                    )
                    try await schedule(record: record, delay: 1)
                    NotificationCenter.default.post(
                        name: .betaFeedbackKitTestFlightScreenshotTaken,
                        object: nil,
                        userInfo: [
                            BetaFeedbackKitScreenshotEventKey.notificationConversationExpected: true
                        ]
                    )
                    betaFeedbackConversationLogger.info(
                        "Restored feedback notification after default tap"
                    )
                } catch {
                    if isCurrentFeedbackConversation(record) {
                        if record.hasAtLeastOneResponse {
                            await completeFeedbackConversation(record, outcome: "open_schedule_failed")
                        } else {
                            let screenshot = activeConversationScreenshot?.id == record.id
                                ? activeConversationScreenshot?.image : nil
                            clearFeedbackConversation(ifCurrent: record)
                            presentTestFlightFeedbackPrompt(capturedScreenshot: screenshot)
                        }
                    }
                }
            }
        case .ignore:
            break
        }
        return true
    }

    /// Returns presentation options only for BetaFeedbackKit-owned notifications.
    /// Forward this from the host delegate's foreground notification callback.
    public func notificationPresentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions? {
        guard notification.request.content.userInfo[BetaFeedbackNotificationIdentifiers.sourceKey] as? String
                == BetaFeedbackNotificationIdentifiers.sourceValue else {
            return nil
        }
        return [.banner, .list, .sound]
    }

    /// Rehydrates a completed report or resumes model processing after a relaunch.
    @MainActor
    public func resumePendingFeedbackConversation() async {
        guard feedbackNotificationMode == .onScreenshot,
              var record = feedbackConversationStore.load() else {
            return
        }
        guard Date.now < record.expiresAt else {
            feedbackConversationStore.clear()
            activeConversationScreenshot = nil
            return
        }
        if record.status == .completed, let report = record.completedReport {
            latestFeedbackReport = report
            return
        }
        if record.reachedResponseLimit {
            await completeFeedbackConversation(record, outcome: "response_limit_migrated")
            return
        }
        if record.status == .processing {
            // An app can be suspended after persisting a response but before model analysis.
            // After relaunch the memory-only image is gone; complete with the durable answers.
            record.status = .processing
            feedbackConversationStore.save(record)
            await processFeedbackConversation(record)
            return
        }
        if record.status == .awaitingResponse {
            let knownIDs = await knownFeedbackNotificationRequestIDs()
            guard !knownIDs.contains(record.pendingRequestID) else { return }
            do {
                try await schedule(record: record, delay: 1)
                betaFeedbackConversationLogger.notice("Restored missing pending feedback notification")
            } catch {
                if record.hasAtLeastOneResponse {
                    await completeFeedbackConversation(record, outcome: "resume_schedule_failed")
                } else {
                    clearFeedbackConversation(ifCurrent: record)
                }
            }
        }
    }

    @MainActor
    public func registerFeedbackNotificationCategories() async {
        guard feedbackNotificationMode == .onScreenshot else { return }
        let center = UNUserNotificationCenter.current()
        await withCheckedContinuation { continuation in
            center.getNotificationCategories { categories in
                center.setNotificationCategories(
                    categories.union(BetaFeedbackNotificationFactory.categories)
                )
                continuation.resume()
            }
        }
    }
}

private extension BetaContentViewModel {
    @MainActor
    func processFeedbackConversation(_ persistedRecord: BetaFeedbackConversationRecord) async {
        var record = persistedRecord
        guard isCurrentFeedbackConversation(record) else {
            betaFeedbackConversationLogger.notice("Discarded superseded model work")
            return
        }
        guard let input = record.analysisInput() else {
            clearFeedbackConversation(ifCurrent: record)
            return
        }

        if record.reachedResponseLimit {
            await completeFeedbackConversation(record, outcome: "response_limit")
            return
        }

        if input.clarificationTurns.last?.isLowInformationResponse == true {
            betaFeedbackConversationLogger.info(
                "Tester could not add more detail; completing without another question"
            )
            await completeFeedbackConversation(record, outcome: "tester_uncertain")
            return
        }

        if input.latestResponseRepeatsEarlierResponse {
            betaFeedbackConversationLogger.info(
                "Tester repeated an earlier response; completing without another question"
            )
            await completeFeedbackConversation(record, outcome: "repeated_response")
            return
        }

        guard feedbackClarificationMode == .onDevice,
              #available(iOS 27.0, *) else {
            await completeFeedbackConversation(record, outcome: "model_disabled")
            return
        }

        guard activeConversationScreenshot?.id == record.id,
              let screenshot = activeConversationScreenshot?.image else {
            await completeFeedbackConversation(record, outcome: "image_unavailable")
            return
        }
        do {
            let result = try await feedbackConversationAnalyzer.analyzeConversation(
                input,
                screenshot: screenshot
            )
            guard isCurrentFeedbackConversation(record) else {
                betaFeedbackConversationLogger.notice("Discarded superseded model result")
                return
            }
            guard let result else {
                betaFeedbackConversationLogger.notice("Foundation Models unavailable; finalizing feedback")
                await completeFeedbackConversation(record, outcome: "model_unavailable")
                return
            }

            record.analysis = result.reportAnalysis
            guard let nextQuestion = result.nextQuestion else {
                betaFeedbackConversationLogger.info("Model completed feedback without another question")
                await completeFeedbackConversation(record, outcome: "model_complete")
                return
            }
            betaFeedbackConversationLogger.info(
                "Clarification decision source=\(result.decisionSource.rawValue, privacy: .public)"
            )

            record.awaitNextQuestion(nextQuestion)
            guard saveFeedbackConversationIfCurrent(record) else {
                betaFeedbackConversationLogger.notice("Discarded superseded follow-up work")
                return
            }
            do {
                try await schedule(record: record, delay: 1)
                betaFeedbackConversationLogger.info(
                    "Scheduled clarification notification \(record.expectedResponseNumber, privacy: .public)"
                )
                AnalyticsManager.logEvent("TestFlight.Feedback.ConversationQuestion", info: [
                    "responseNumber": String(record.expectedResponseNumber),
                    "responseStyle": responseStyleName(nextQuestion.responseStyle)
                ])
            } catch {
                await completeFeedbackConversation(record, outcome: "followup_schedule_failed")
            }
        } catch is CancellationError {
            if isCurrentFeedbackConversation(record) {
                // The processing state is already durable and setup() will resume it.
                betaFeedbackConversationLogger.notice(
                    "Model processing cancelled; durable response will resume"
                )
            } else {
                betaFeedbackConversationLogger.notice("Discarded superseded cancellation")
            }
        } catch {
#if DEBUG
            print("[BetaFeedbackKitLLM][conversation.error] \(String(reflecting: error))")
#endif
            betaFeedbackConversationLogger.error(
                "Model processing failed: \(String(describing: type(of: error)), privacy: .public)"
            )
            await completeFeedbackConversation(record, outcome: "model_error")
        }
    }

    @MainActor
    func completeFeedbackConversation(
        _ persistedRecord: BetaFeedbackConversationRecord,
        outcome: String
    ) async {
        var record = persistedRecord
        guard isCurrentFeedbackConversation(record) else {
            betaFeedbackConversationLogger.notice("Discarded superseded completion work")
            return
        }
        guard let input = record.analysisInput() else { return }
        let finalAnalysis = record.analysis.map {
            BetaFeedbackClarificationAnalysis(
                summary: $0.summary,
                category: $0.category,
                needsClarification: false,
                clarificationQuestion: nil
            )
        }
        let report = BetaFeedbackReport(
            originalFeedback: input.originalFeedback,
            questionID: input.questionID,
            questionTitle: input.questionTitle,
            analysis: finalAnalysis,
            clarificationTurns: input.clarificationTurns,
            metadata: input.metadata,
            developerContext: input.developerContext,
            activeStates: input.activeStates,
            diagnosticContext: input.diagnosticContext
        )
        record.complete(with: report)
        guard saveFeedbackConversationIfCurrent(record) else {
            betaFeedbackConversationLogger.notice("Discarded superseded report work")
            return
        }
        latestFeedbackReport = report
        testFlightFeedbackAnswer = report.originalFeedback
        testFlightFeedbackQuestionId = report.questionID
        hasShownTestFlightFeedbackPrompt = true
        activeConversationScreenshot = nil
        onFeedbackPrepared?(report)
        let copied = copyFeedbackToPasteboard(report: report)

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [record.pendingRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [record.pendingRequestID])
        do {
            try await center.add(
                BetaFeedbackNotificationFactory.completionRequest(
                    copied: copied,
                    conversationID: record.id
                )
            )
            if !isCurrentFeedbackConversation(record) {
                let completionID = BetaFeedbackNotificationIdentifiers
                    .completionRequestIdentifier(for: record.id)
                center.removePendingNotificationRequests(withIdentifiers: [completionID])
                center.removeDeliveredNotifications(withIdentifiers: [completionID])
            }
        } catch {
            // The report remains persisted and available even if the confirmation cannot appear.
        }
        AnalyticsManager.logEvent("TestFlight.Feedback.ConversationComplete", info: [
            "outcome": outcome,
            "responseCount": String(record.responses.count),
            "copied": copied ? "true" : "false"
        ])
        betaFeedbackConversationLogger.info(
            "Completed feedback conversation outcome=\(outcome, privacy: .public) responses=\(record.responses.count, privacy: .public)"
        )
    }

    @MainActor
    func schedule(record: BetaFeedbackConversationRecord, delay: TimeInterval) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [record.pendingRequestID])
        try await center.add(BetaFeedbackNotificationFactory.request(for: record, delay: delay))
        guard isCurrentFeedbackConversation(record) else {
            center.removePendingNotificationRequests(withIdentifiers: [record.pendingRequestID])
            center.removeDeliveredNotifications(withIdentifiers: [record.pendingRequestID])
            throw CancellationError()
        }
    }

    @MainActor
    func clearFeedbackConversation(ifCurrent record: BetaFeedbackConversationRecord) {
        guard clearFeedbackConversationIfCurrent(record) else { return }
        if activeConversationScreenshot?.id == record.id {
            activeConversationScreenshot = nil
        }
    }

    @MainActor
    func knownFeedbackNotificationRequestIDs() async -> Set<String> {
        let pendingIDs: Set<String> = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
        let deliveredIDs: Set<String> = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: Set(notifications.map(\.request.identifier)))
            }
        }
        return pendingIDs.union(deliveredIDs)
    }

    func responseStyleName(_ style: BetaFeedbackConversationResponseStyle) -> String {
        switch style {
        case .text: "text"
        case .yesNo: "yes_no"
        case .frequency: "frequency"
        case .responsivenessScope: "responsiveness_scope"
        }
    }
}
#endif

enum BetaFeedbackNotificationReply: Sendable, Equatable {
    case answer(String)
    case finish
    case open
    case ignore

    static func parse(
        actionIdentifier: String,
        userText: String?,
        question: BetaFeedbackConversationQuestion
    ) -> Self {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .open
        case BetaFeedbackNotificationIdentifiers.finishAction:
            return .finish
        case BetaFeedbackNotificationIdentifiers.textAction:
            guard question.responseStyle == .text, let userText else { return .ignore }
            return .answer(userText)
        case BetaFeedbackNotificationIdentifiers.yesAction:
            return question.responseStyle == .yesNo ? .answer("Yes") : .ignore
        case BetaFeedbackNotificationIdentifiers.noAction:
            return question.responseStyle == .yesNo ? .answer("No") : .ignore
        case BetaFeedbackNotificationIdentifiers.everyTimeAction:
            return question.responseStyle == .frequency ? .answer("Every time") : .ignore
        case BetaFeedbackNotificationIdentifiers.onceAction:
            return question.responseStyle == .frequency ? .answer("Only once") : .ignore
        case BetaFeedbackNotificationIdentifiers.wholeAppAction:
            return question.responseStyle == .responsivenessScope ? .answer("Whole app") : .ignore
        case BetaFeedbackNotificationIdentifiers.oneControlAction:
            return question.responseStyle == .responsivenessScope ? .answer("Just one control") : .ignore
        default:
            return .ignore
        }
    }
}

#if os(iOS)
enum BetaFeedbackNotificationFactory {
    static var categories: Set<UNNotificationCategory> {
        [
            initialTextCategory,
            textCategory,
            optionCategory(
                identifier: BetaFeedbackNotificationIdentifiers.yesNoCategory,
                actions: [
                    action(BetaFeedbackNotificationIdentifiers.yesAction, "Yes"),
                    action(BetaFeedbackNotificationIdentifiers.noAction, "No")
                ]
            ),
            optionCategory(
                identifier: BetaFeedbackNotificationIdentifiers.frequencyCategory,
                actions: [
                    action(BetaFeedbackNotificationIdentifiers.everyTimeAction, "Every time"),
                    action(BetaFeedbackNotificationIdentifiers.onceAction, "Only once")
                ]
            ),
            optionCategory(
                identifier: BetaFeedbackNotificationIdentifiers.scopeCategory,
                actions: [
                    action(BetaFeedbackNotificationIdentifiers.wholeAppAction, "Whole app"),
                    action(BetaFeedbackNotificationIdentifiers.oneControlAction, "Just one control")
                ]
            )
        ]
    }

    static func request(for record: BetaFeedbackConversationRecord, delay: TimeInterval = 1) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = record.responses.isEmpty ? "Quick beta feedback" : "One quick question"
        content.body = record.pendingQuestion.text
        content.sound = .default
        content.threadIdentifier = BetaFeedbackNotificationIdentifiers.prefix
        content.categoryIdentifier = categoryIdentifier(
            for: record.pendingQuestion.responseStyle,
            offersFinish: record.shouldOfferFinishAction
        )
        content.userInfo = BetaFeedbackNotificationEnvelope(
            conversationID: record.id,
            responseNumber: record.expectedResponseNumber
        ).userInfo

        return UNNotificationRequest(
            identifier: record.pendingRequestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        )
    }

    static func completionRequest(copied: Bool, conversationID: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = copied ? "Feedback report copied" : "Feedback report ready"
        content.body = BetaFeedbackCompletionCopy.body(copied: copied)
        content.sound = .default
        content.threadIdentifier = BetaFeedbackNotificationIdentifiers.prefix
        content.userInfo = [
            BetaFeedbackNotificationIdentifiers.sourceKey: BetaFeedbackNotificationIdentifiers.sourceValue,
            BetaFeedbackNotificationIdentifiers.schemaKey: BetaFeedbackNotificationIdentifiers.schemaVersion,
            BetaFeedbackNotificationIdentifiers.conversationIDKey: conversationID.uuidString,
            "betafeedbackkit_completion": true
        ]
        return UNNotificationRequest(
            identifier: BetaFeedbackNotificationIdentifiers.completionRequestIdentifier(
                for: conversationID
            ),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
    }

    private static var initialTextCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: BetaFeedbackNotificationIdentifiers.initialTextCategory,
            actions: [textReplyAction],
            intentIdentifiers: [],
            options: []
        )
    }

    private static var textCategory: UNNotificationCategory {
        let finish = action(BetaFeedbackNotificationIdentifiers.finishAction, "Finish report")
        return UNNotificationCategory(
            identifier: BetaFeedbackNotificationIdentifiers.textCategory,
            actions: [textReplyAction, finish],
            intentIdentifiers: [],
            options: []
        )
    }

    private static var textReplyAction: UNTextInputNotificationAction {
        let reply = UNTextInputNotificationAction(
            identifier: BetaFeedbackNotificationIdentifiers.textAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a short answer"
        )
        return reply
    }

    private static func optionCategory(
        identifier: String,
        actions: [UNNotificationAction]
    ) -> UNNotificationCategory {
        let finish = action(BetaFeedbackNotificationIdentifiers.finishAction, "Finish report")
        return UNNotificationCategory(
            identifier: identifier,
            actions: actions + [finish],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func action(_ identifier: String, _ title: String) -> UNNotificationAction {
        UNNotificationAction(identifier: identifier, title: title, options: [])
    }

    private static func categoryIdentifier(
        for style: BetaFeedbackConversationResponseStyle,
        offersFinish: Bool
    ) -> String {
        switch style {
        case .text:
            offersFinish
                ? BetaFeedbackNotificationIdentifiers.textCategory
                : BetaFeedbackNotificationIdentifiers.initialTextCategory
        case .yesNo: BetaFeedbackNotificationIdentifiers.yesNoCategory
        case .frequency: BetaFeedbackNotificationIdentifiers.frequencyCategory
        case .responsivenessScope: BetaFeedbackNotificationIdentifiers.scopeCategory
        }
    }
}
#endif
