import Foundation
import AppKit

struct CodexAppInfo {
    let bundleURL: URL
    let version: String
    let teamID: String?
    let signatureValid: Bool
}

enum CodexLocator {
    static let bundleID = "com.openai.codex"
    static let expectedTeamID = "2DC432GLL2"

    static func locate() -> CodexAppInfo? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app",
            "\(home)/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "\(home)/Applications/Codex.app",
        ]
        var bundleURL: URL?
        for path in candidates where bundleIDMatches(URL(fileURLWithPath: path)) {
            bundleURL = URL(fileURLWithPath: path)
            break
        }
        if bundleURL == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           bundleIDMatches(url) {
            bundleURL = url
        }
        guard let bundleURL else { return nil }

        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let (teamID, signatureValid) = validateSignature(bundleURL)
        return CodexAppInfo(bundleURL: bundleURL, version: version, teamID: teamID, signatureValid: signatureValid)
    }

    private static func bundleIDMatches(_ url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleID
    }

    private static func validateSignature(_ bundle: URL) -> (teamID: String?, valid: Bool) {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", bundle.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        var verifyOK = false
        if let _ = try? verify.run() {
            verify.waitUntilExit()
            verifyOK = verify.terminationStatus == 0
        }

        let inspect = Process()
        let pipe = Pipe()
        inspect.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        inspect.arguments = ["-dv", "--verbose=4", bundle.path]
        inspect.standardOutput = pipe
        inspect.standardError = pipe
        var teamID: String?
        if let _ = try? inspect.run() {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            inspect.waitUntilExit()
            teamID = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("TeamIdentifier=") })
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
        }
        return (teamID, verifyOK && teamID == expectedTeamID)
    }
}
