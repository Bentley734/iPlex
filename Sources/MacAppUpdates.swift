#if os(macOS)
import AppKit
import SwiftUI
import Foundation
import CryptoKit

final class UpdateOperation: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var stopped = false
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var failure: Error?
    private var done: DispatchSemaphore?
    private var limit = 0
    private var redirects = false
    func cancel() { lock.lock(); stopped = true; let active = task; lock.unlock(); active?.cancel() }
    func check() throws { lock.lock(); let canceled = stopped; lock.unlock(); if canceled { throw UpdateError("Update canceled. Your current files were kept.") } }
    func fetch(_ url: URL, limit: Int, redirects: Bool = false) throws -> Data {
        try check()
        self.limit = limit; self.redirects = redirects; bytes = Data(); failure = nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("iPlex AppUpdate", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0); done = semaphore
        let download = session.dataTask(with: request)
        lock.lock(); task = download; let canceled = stopped; lock.unlock()
        if canceled { throw UpdateError("Update canceled.") }
        download.resume()
        guard semaphore.wait(timeout: .now() + 190) == .success else { download.cancel(); throw UpdateError("The download timed out. Try again later.") }
        try check()
        if let error = failure { throw error }
        return bytes
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            failure = UpdateError("The server returned an unsuccessful or oversized response."); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > limit { failure = UpdateError("The download exceeded its size limit."); dataTask.cancel() } else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if failure == nil { failure = error }; done?.signal() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        let allowed = redirects && request.url?.scheme == "https" && (host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com")
        completionHandler(allowed ? request : nil)
    }
}

struct MacRelease {
    let version: String
    let url: URL
    let digest: String
    let size: Int
}
enum AppUpdate {
    static let repository = "https://github.com/Bentley734/iPlex"
    static let assetName = "iPlex.macOS.zip"
    static func parse(_ data: Data, current: String) throws -> MacRelease? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["draft"] as? Bool == false, root["prerelease"] as? Bool == false,
              let tag = root["tag_name"] as? String, tag.range(of: "^v?[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              root["html_url"] as? String == repository + "/releases/tag/" + tag,
              let assets = root["assets"] as? [[String: Any]] else { throw UpdateError("Invalid GitHub release metadata.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.compare(current, options: .numeric) == .orderedDescending else { return nil }
        let matching = assets.filter { $0["name"] as? String == assetName }
        guard matching.count == 1 else { throw UpdateError("A newer release exists, but its macOS package has not been published yet.") }
        let asset = matching[0]
        guard let address = asset["browser_download_url"] as? String, address == repository + "/releases/download/" + tag + "/" + assetName,
              let url = URL(string: address), let digest = asset["digest"] as? String,
              digest.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              let size = asset["size"] as? Int, size > 0, size <= 128 * 1024 * 1024 else { throw UpdateError("The Mac package is missing a valid digest, URL, or size.") }
        return MacRelease(version: version, url: url, digest: String(digest.dropFirst(7)).lowercased(), size: size)
    }
    static func verify(_ data: Data, release: MacRelease) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.size, hash == release.digest else { throw UpdateError("The download did not match GitHub's SHA-256 digest and size.") }
    }
    @discardableResult static func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        let out = Pipe(); process.standardOutput = out; process.standardError = out
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError("Package verification failed. " + output) }
        return output
    }
    static func team(_ app: URL) throws -> String? {
        let details = try run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let value = details.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return value == "not set" ? nil : value
    }
    static func stage(_ data: Data, release: MacRelease, directory: URL) throws -> URL {
        try verify(data, release: release)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("update.zip")
        try data.write(to: archive, options: .atomic)
        let listing = try run("/usr/bin/zipinfo", ["-1", archive.path])
        for entry in listing.split(separator: "\n").map(String.init) {
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."), entry.hasPrefix("iPlex.app/") || entry.hasPrefix("__MACOSX/") else { throw UpdateError("Unexpected archive path.") }
        }
        let details = try run("/usr/bin/zipinfo", ["-l", archive.path])
        var uncompressed = 0
        for line in details.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first?.hasPrefix("l") == true { throw UpdateError("Symbolic links are not accepted in Mac updates.") }
            if let first = fields.first, first.hasPrefix("-") || first.hasPrefix("d") {
                guard fields.count > 3, let size = Int(fields[3]), size >= 0,
                      size <= 512 * 1024 * 1024 - uncompressed else {
                    throw UpdateError("Invalid or oversized archive entry.")
                }
                uncompressed += size
            }
        }
        let extracted = directory.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let candidate = extracted.appendingPathComponent("iPlex.app")
        if let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(extracted.standardizedFileURL.path + "/") else { throw UpdateError("Archive link escaped the package.") }
            }
        }
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "net.bentley734.musicroom",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              let executable = bundle.executableURL, executable.standardizedFileURL == candidate.appendingPathComponent("Contents/MacOS/iPlex").standardizedFileURL, fm.isExecutableFile(atPath: executable.path) else { throw UpdateError("The update has the wrong app identity or version.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        return candidate
    }
}


@MainActor
final class MacAppUpdates: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    private var operation: UpdateOperation?
    private var staged: URL?
    private var acknowledged = false

    private static var updateRoot: URL {
        URL.applicationSupportDirectory.appending(path: "iPlex/AppUpdates", directoryHint: .isDirectory)
    }

    var buttonTitle: String { busy ? "Cancel" : ready ? "Restart to Update" : "Check for Updates" }

    func act() {
        if let operation { operation.cancel(); return }
        if let staged { install(staged); return }
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        let download = UpdateOperation()
        operation = download
        busy = true
        status = "Checking GitHub…"
        let root = Self.updateRoot
        let installed = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async {
            let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let result: Result<(URL, String)?, Error> = Result {
                let metadata = try download.fetch(URL(string: "https://api.github.com/repos/Bentley734/iPlex/releases/latest")!, limit: 2 * 1024 * 1024)
                guard let release = try AppUpdate.parse(metadata, current: version) else { return nil }
                DispatchQueue.main.async { self.status = "Downloading iPlex \(release.version)…" }
                let package = try download.fetch(release.url, limit: release.size, redirects: true)
                let app = try AppUpdate.stage(package, release: release, directory: directory)
                if let team = try AppUpdate.team(installed), try AppUpdate.team(app) != team {
                    throw UpdateError("The update was signed by a different developer.")
                }
                try download.check()
                return (app, release.version)
            }
            DispatchQueue.main.async {
                self.operation = nil
                self.busy = false
                do {
                    try download.check()
                    if let (app, release) = try result.get() {
                        self.staged = app
                        self.ready = true
                        self.status = "iPlex \(release) is ready to install."
                    } else {
                        self.status = "iPlex \(version) is up to date."
                    }
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func install(_ candidate: URL) {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        let files = FileManager.default
        let id = UUID().uuidString
        let stage = folder.appending(path: ".iPlex-update-" + id, directoryHint: .isDirectory)
        let next = stage.appending(path: "Candidate.app")
        let previous = stage.appending(path: "Previous.app")
        let helper = Self.updateRoot.appending(path: "install-" + id + ".sh")
        let ack = Self.updateRoot.appending(path: "ack-" + id)
        do {
            guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"),
                  !app.lastPathComponent.hasPrefix("Previous."),
                  files.isWritableFile(atPath: folder.path) else {
                throw UpdateError("Move iPlex to a writable Applications folder and try again.")
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "net.bentley734.musicroom")
            guard !running.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }) else {
                throw UpdateError("Close the other iPlex window before updating.")
            }
            try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try files.copyItem(at: candidate, to: next)
            try AppUpdate.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", next.path])
            guard let template = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
                throw UpdateError("The update helper is missing from this build.")
            }
            try files.copyItem(at: template, to: helper)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), app.path,
                                 next.path, previous.path, Self.updateRoot.appending(path: "install.log").path, ack.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            try? files.removeItem(at: candidate.deletingLastPathComponent().deletingLastPathComponent())
            NSApp.terminate(nil)
        } catch {
            try? files.removeItem(at: stage)
            try? files.removeItem(at: helper)
            status = error.localizedDescription
        }
    }

    private static var acknowledgmentURL: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--update-ack"), args.indices.contains(index + 1) else { return nil }
        let ack = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        guard ack.deletingLastPathComponent().path == updateRoot.standardizedFileURL.path,
              ack.lastPathComponent.hasPrefix("ack-"),
              UUID(uuidString: String(ack.lastPathComponent.dropFirst(4))) != nil else { return nil }
        return ack
    }

    static func recordLaunchingProcess() {
        guard let ack = acknowledgmentURL else { return }
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(to: ack.appendingPathExtension("pid"), atomically: true, encoding: .utf8)
    }

    func acknowledgeLaunch() {
        guard !acknowledged, let ack = Self.acknowledgmentURL else { return }
        do {
            try Data("ready".utf8).write(to: ack, options: .atomic)
            acknowledged = true
        } catch {
            NSLog("Could not acknowledge app update: %@", error.localizedDescription)
        }
    }
}
#endif
