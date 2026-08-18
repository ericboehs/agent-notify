// claude-notifier - posts a Claude Code banner, and runs its action when clicked
//
// This replaces terminal-notifier, which posts through NSUserNotification. That
// API is deprecated, and on macOS 26 the half of it that matters here is simply
// gone: banners still appear, but the click never relaunches the app, so
// -execute silently does nothing and clicking a banner stops focusing the pane
// that raised it. UNUserNotificationCenter is the supported path, and it hands
// a click back to the posting app's delegate.
//
// Built into the branded app bundle by claude-notify-app. The flag names are
// terminal-notifier's, so claude-notify's call sites did not have to change:
//
//   claude-notifier -title T [-subtitle S] -message M [-group ID]
//                   [-contentImage PATH] [-execute SHELL]
//
// With no arguments the process is being relaunched by a click, and its only
// job is to run the command the clicked notification carries.

import AppKit
import UserNotifications

let args = CommandLine.arguments

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let title = flagValue("-title")
let subtitle = flagValue("-subtitle")
let message = flagValue("-message")
let group = flagValue("-group")
let execute = flagValue("-execute")
let image = flagValue("-contentImage")
let isPost = (message != nil || title != nil)

func note(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Attachments accept image, audio and video files, and .icns is none of those,
// so whatever was handed in is redrawn as a PNG first. The system copies the
// file into its own store as the notification is posted, which is why a
// throwaway in the temp directory is enough.
func attachment(from path: String) -> UNNotificationAttachment? {
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: path)),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-notify-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("thumb.png")
    guard (try? png.write(to: dest)) != nil else { return nil }
    return try? UNNotificationAttachment(identifier: "thumb", url: dest, options: nil)
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        guard isPost else {
            // Launched by a click. The response arrives on the delegate just
            // after launch; the timer is only here so a launch that turns out
            // to carry nothing does not leave a process behind.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
            return
        }

        // A hook is waiting on this process, so it must not sit forever on the
        // first-run permission alert: long enough for someone to click Allow,
        // short enough that a Claude turn never stalls on it twice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            note("timed out waiting on the notification system")
            exit(1)
        }

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { note("authorization: \(error)") }
            guard granted else { note("notifications not authorized"); exit(1) }

            let content = UNMutableNotificationContent()
            content.title = title ?? ""
            if let subtitle { content.subtitle = subtitle }
            content.body = message ?? ""
            if let execute { content.userInfo = ["command": execute] }
            if let group { content.threadIdentifier = group }
            if let image, let att = attachment(from: image) { content.attachments = [att] }

            // Reusing the identifier is what makes a session's second banner
            // replace its first instead of stacking - terminal-notifier's
            // -group, by another name. The thread id groups them in
            // Notification Center as well.
            let req = UNNotificationRequest(identifier: group ?? UUID().uuidString,
                                            content: content, trigger: nil)
            center.add(req) { err in
                if let err { note("post failed: \(err)"); exit(1) }
                exit(0)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let cmd = response.notification.request.content.userInfo["command"] as? String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            try? p.run()
            p.waitUntilExit()
        }
        completionHandler()
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
