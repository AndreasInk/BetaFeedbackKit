# AGENTS.md

## Product stance

BetaFeedbackKit turns a screenshot and one short tester response into feedback a developer can act on. Tester effort is the constraint: if a feature needs an account, backend, long form, or technical language, it is probably the wrong feature.

## Non-negotiables

- Preserve the tester's original words. Generated summaries must be extractive, and generated questions must not invent facts, causes, or reproduction steps.
- Intelligent clarification and notification conversations are opt-in. Denied permissions, unavailable models, and older systems must shorten or fall back without losing any response already captured.
- Never log prompts, tester responses, screenshots, or developer context in release builds. Notification `userInfo` carries routing data only.
- Be precise about the boundary: BetaFeedbackKit prepares and optionally copies a report; it does not submit feedback to TestFlight.
- Keep the public API small and stable. Make breaking changes only when intentional, documented, and worth the migration.

## Implementation rules

- Package: `BetaFeedbackKit`; sources: `Sources/BetaFeedbackKit`; tests: `Tests/BetaFeedbackKitTests`.
- Support iOS 17+ and macOS 14+. Guard iOS 27 and TestFlight-only behavior explicitly and keep cross-platform builds green.
- Prefer small, composable SwiftUI views and direct state flow over new abstractions.
- The host app owns `UNUserNotificationCenter.delegate`; BetaFeedbackKit may register categories and handle only its own routed responses.
- Treat notification conversations as lifecycle state: persist before async work, handle cancellation and relaunch, expire stale records, and replace old notifications cleanly.
- Add observability for outcomes and failure reasons, never for private feedback content.
- On iOS/macOS 27 every clarification model request needs the original session image. Capture only the mounted app window (or explicit provider) before feedback UI; never recapture a later screen as fallback. Keep images in memory and finish with preserved answers when unavailable.

## Verification

- Run `swift build` and `swift test`.
- Model evaluations are opt-in through `Evaluations/run_image_evals.py`; inspect images, raw questions, judge calibration and matched-case coverage. Keep outputs outside Git. Do not promote candidate prompts before the blinded review and real-reply acceptance in `Evaluations/README.md`.
- Add focused regression tests for logic and state transitions.
- Visually inspect UI changes.
- For notification or lifecycle changes, verify permission denial, model unavailability, background/relaunch, and repeated screenshots on iPhone when possible.
- Update README examples when behavior or public API changes.
