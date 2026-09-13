# BetaFeedbackDemo

This SwiftUI host resolves `BetaFeedbackKit` from the local repository using
`.package(path: "../..")`. It exercises the real feedback sheet, on-device clarification,
developer context, report preparation, and pasteboard export without changing another app's
package lockfile.

To generate the installable iPhone project, run:

```sh
xcodegen generate --spec project.yml
```

To run the macOS Swift package directly:

```sh
swift run BetaFeedbackDemo
```

Choose **Give feedback about this screen**. Automatic capture takes the app window before
opening the sheet, so the image describes Settings rather than the feedback form or keyboard.
Try a vague report (“This section is hard to use”) and a specific request (“Put the four
General toggles in a subsection called General so Settings is shorter”). Review whether any
follow-up would add a useful fact; a model response alone does not prove quality. The finished
report appears in the demo and can be copied from the feedback flow.

The default remains the minimal prompt pending the blinded old/new evaluation and six real
reply pilot. The evaluation harness exercises the candidate through the same image pipeline.

On iPhone, choose **Start notification feedback** to request notification access and schedule the
first reply notification. Taking a screenshot exercises the same `.onScreenshot` path. The demo
owns the notification-center delegate and forwards BetaFeedbackKit banners and responses.

The on-device clarification path requires a supported OS with Apple Intelligence available.
When the model is unavailable, the package intentionally prepares the original response without
a clarification.

For lifecycle checks, start a notification conversation, terminate and relaunch the app, then
reply. The response must remain in the prepared report, without a model follow-up because the
original image was memory-only. Also test denied notification access, repeated screenshots,
canceling a sheet, and unavailable Apple Intelligence. Use the model eval artifacts to inspect
exact input pixels; this demo does not write screenshots or tester responses to disk.
