import BetaFeedbackKit
import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

private enum DemoPrompt {
    static var name: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--betafeedback-evaluate-candidate") { return "candidate" }
        #endif
        return "baseline"
    }
}

@main
struct BetaFeedbackDemoApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate
#endif

    @State private var feedback = BetaContentViewModel(
        feedbackQuestions: [
            .init(
                id: "screenshot-feedback",
                title: "What feedback do you have about this screen?",
                helperText: "One sentence is perfect.",
                placeholder: "Describe what feels unclear or what you would change"
            )
        ],
        allowsFeedbackPasteboardExport: true,
        feedbackContextProvider: {
            [
                "demo_prompt_variant": DemoPrompt.name,
                "feature": "settings_information_architecture",
                "screen": "settings",
                "screen_summary": "Settings and controls",
                "domain_context": "Settings groups related controls into sections. A destination row can open a subsection when a group should not be shown inline."
            ]
        },
        feedbackClarificationMode: .onDevice,
        feedbackNotificationMode: .onScreenshot
    )

    var body: some Scene {
        WindowGroup {
            DemoSettingsView(feedback: feedback)
#if os(iOS)
                .task {
                    appDelegate.feedbackViewModel = feedback
                }
#endif
        }
    }
}

private struct DemoSettingsView: View {
    @Bindable var feedback: BetaContentViewModel
    @State private var notificationStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Daily reminders", isOn: .constant(true))
                    Toggle("Progress sounds", isOn: .constant(false))
                    Toggle("Weekly summary", isOn: .constant(true))
                    Toggle("Show goal details", isOn: .constant(true))
                }

                if let report = feedback.latestFeedbackReport {
                    Section("Prepared feedback") {
                        Text(report.formattedText)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                Section("BetaFeedbackKit") {
                    Text("Testing \(DemoPrompt.name) clarification prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Give feedback about this screen") {
                        let url = URL(string: "betafeedbackdemo://\(BetaContentViewModel.DeepLink.feedbackHost)")!
                        _ = feedback.handleDeepLink(url)
                    }

#if os(iOS)
                    Button("Start notification feedback") {
                        Task {
                            let started = await feedback.startFeedbackNotificationConversation()
                            notificationStatus = started
                                ? "Notification scheduled. It should arrive in about two seconds."
                                : "Could not schedule it. Check notification access in Settings."
                        }
                    }

                    if let notificationStatus {
                        Text(notificationStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
#endif

                    Text("Try: “Other settings screens would have a sub section here rather than all the elements on one screen.”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings Demo")
#if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
#endif
        }
        .beta(viewModel: feedback)
        .task {
            feedback.setup()
        }
    }
}

#if os(iOS)
private final class DemoAppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    var feedbackViewModel: BetaContentViewModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if feedbackViewModel?.handleNotificationResponse(
            response,
            completionHandler: completionHandler
        ) == true {
            return
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(
            feedbackViewModel?.notificationPresentationOptions(for: notification) ?? []
        )
    }
}
#endif
