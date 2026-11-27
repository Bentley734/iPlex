import AppKit
import WebKit

extension AppDelegate {
    func updateState(_ kind: String, _ text: String, _ button: String = "Check now", busy: Bool = false, ready: Bool = false) {
        let args: [Any] = [kind, text, button, busy, ready]
        guard let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.macUpdateState?.(...\(json))", completionHandler: nil)
    }
    func startCatalogUpdate() {
        if let operation = catalogOperation { operation.cancel(); return }
        let operation = UpdateOperation(); catalogOperation = operation
        let previous = activeCatalog
        updateState("catalog", "Checking the published metadata…", "Cancel", busy: true)
        DispatchQueue.global(qos: .utility).async {
            do {
                var blobs = [Data]()
                for file in CatalogUpdate.files {
                    try operation.check()
                    blobs.append(try operation.fetch(URL(string: "https://tooldriveproject.net/data/" + file)!, limit: 16 * 1024 * 1024))
                }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
                let candidate = try CatalogUpdate.compile(blobs, date: formatter.string(from: Date()))
                try CatalogUpdate.protect(previous, candidate)
                let summary = CatalogUpdate.summary(previous, candidate)
                try operation.check()
                DispatchQueue.main.async {
                    do {
                        try operation.check()
                        try FileManager.default.createDirectory(at: self.dataURL, withIntermediateDirectories: true)
                        let cache: [String: Any] = ["catalog": candidate, "checkedAt": ISO8601DateFormatter().string(from: Date())]
                        try CatalogUpdate.serialize(cache).write(to: self.dataURL.appendingPathComponent("catalog-update.json"), options: .atomic)
                        self.activeCatalog = candidate
                        let json = self.javascriptJSON(candidate)
                        self.web.evaluateJavaScript("window.applyMacCatalog(\(json))") { _, error in
                            self.updateState("catalog", error == nil ? summary + " Checked just now." : "Saved update. Reopen the app to load it.")
                        }
                    } catch { self.updateState("catalog", error.localizedDescription) }
                    self.catalogOperation = nil
                }
            } catch { DispatchQueue.main.async { self.catalogOperation = nil; self.updateState("catalog", error.localizedDescription) } }
        }
    }
    func startAppUpdate() { updateState("app", "Check for updates in iPlex Settings.") }
    func javascriptJSON(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
