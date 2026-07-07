import AppKit
import Foundation

struct XcodeProject: Equatable {
    let name: String
    let path: String
    var directoryPath: String {
        if path.isEmpty { return NSHomeDirectory() }
        let dir = (path as NSString).deletingLastPathComponent
        // A bogus path (e.g. AppleScript "missing value" leaking through) would
        // make the terminal chdir fail silently and start in the app's cwd.
        guard FileManager.default.fileExists(atPath: dir) else { return NSHomeDirectory() }
        return dir
    }

    static func == (lhs: XcodeProject, rhs: XcodeProject) -> Bool {
        lhs.name == rhs.name && lhs.path == rhs.path
    }
}

class XcodeDetector {
    static let shared = XcodeDetector()

    /// Detects the frontmost Xcode project
    func detectFrontmostProject() -> XcodeProject? {
        if let project = queryFrontViaAppleScript() {
            return project
        }
        if let project = queryViaWindowTitle() {
            return project
        }
        return nil
    }

    /// Detects ALL open Xcode workspace documents
    func detectAllProjects() -> [XcodeProject] {
        if let projects = queryAllViaAppleScript(), !projects.isEmpty {
            return projects
        }
        return allProjectsViaWindowTitles()
    }

    // MARK: - AppleScript

    private func isXcodeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }
    }

    private func queryFrontViaAppleScript() -> XcodeProject? {
        guard isXcodeRunning() else { return nil }

        let script = """
        tell application "Xcode"
            if (count of workspace documents) > 0 then
                set activeDoc to front workspace document
                set docPath to path of activeDoc
                if docPath is missing value then set docPath to ""
                set docName to name of activeDoc
                return docName & "|||" & docPath
            end if
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        guard let resultString = result.stringValue else { return nil }
        return parseProject(from: resultString)
    }

    private func queryAllViaAppleScript() -> [XcodeProject]? {
        guard isXcodeRunning() else { return nil }

        let script = """
        tell application "Xcode"
            set output to ""
            repeat with doc in workspace documents
                set docName to name of doc
                set docPath to path of doc
                if docPath is missing value then set docPath to ""
                set output to output & docName & "|||" & docPath & ":::"
            end repeat
            return output
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        guard let resultString = result.stringValue, !resultString.isEmpty else { return nil }

        var projects: [XcodeProject] = []
        let entries = resultString.components(separatedBy: ":::")
        for entry in entries where !entry.isEmpty {
            if let project = parseProject(from: entry) {
                projects.append(project)
            }
        }
        return projects
    }

    private func parseProject(from string: String) -> XcodeProject? {
        let components = string.components(separatedBy: "|||")
        guard components.count == 2 else { return nil }

        let name = components[0]
            .replacingOccurrences(of: ".xcodeproj", with: "")
            .replacingOccurrences(of: ".xcworkspace", with: "")
        // Older builds let AppleScript's `missing value` coerce into the string —
        // and it's still possible if the script-side guard is bypassed.
        var path = components[1]
        if path == "missing value" { path = "" }

        return XcodeProject(name: name, path: path)
    }

    // MARK: - Window title fallback

    private func queryViaWindowTitle() -> XcodeProject? {
        let projects = allProjectsViaWindowTitles()
        return projects.first
    }

    private func allProjectsViaWindowTitles() -> [XcodeProject] {
        guard let xcode = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }) else { return [] }

        let pid = xcode.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<String>()
        var projects: [XcodeProject] = []

        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let windowName = window[kCGWindowName as String] as? String,
                  !windowName.isEmpty,
                  window[kCGWindowLayer as String] as? Int == 0 else { continue }

            let projectName = windowName.components(separatedBy: " — ").first
                ?? windowName.components(separatedBy: " – ").first
                ?? windowName

            let trimmed = projectName.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                projects.append(XcodeProject(name: trimmed, path: ""))
            }
        }
        return projects
    }
}
