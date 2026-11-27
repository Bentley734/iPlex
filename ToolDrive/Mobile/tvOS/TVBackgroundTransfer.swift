import CoreImage.CIFilterBuiltins
import Darwin
import Network
import SwiftUI

struct TVBackgroundTransfer: View {
    let archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var receiver: WallpaperReceiver?
    @State private var address: String?
    @State private var message = "Preparing a link…"
    @State private var imported = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Send a Background Photo").font(.title.bold())
            if let address, let code = Self.qrImage(address) {
                Image(decorative: code, scale: 1).interpolation(.none)
                    .resizable().scaledToFit().frame(width: 260, height: 260)
                    .padding(18).background(.white, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("QR code for the background photo upload")
                Text("Scan the code or open this address on a device on the same network.")
                    .multilineTextAlignment(.center)
                Text(address).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(message).foregroundStyle(.secondary)
            Button(imported ? "Done" : "Close") { dismiss() }
        }
        .frame(maxWidth: 1050)
        .padding(50)
        .task {
            guard receiver == nil else { return }
            let transfer = WallpaperReceiver()
            receiver = transfer
            transfer.start { link in
                address = link
                message = link == nil ? "Connect Apple TV to the same Wi-Fi or wired network and try again." : "Waiting for a photo…"
            } receive: { data in
                do {
                    try await archive.importBackground { data }
                    imported = true
                    address = nil
                    message = "Custom background applied."
                    return true
                } catch {
                    message = error.localizedDescription
                    return false
                }
            }
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, !imported else { return }
            transfer.stop()
            address = nil
            message = "The link expired. Reopen this screen to start a new transfer."
        }
        .onDisappear { receiver?.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                receiver?.stop()
                if !imported {
                    address = nil
                    message = "The link expired. Reopen this screen to start a new transfer."
                }
            }
        }
    }

    private static func qrImage(_ address: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

final class WallpaperReceiver {
    private let queue = DispatchQueue(label: "Tool Drive background transfer")
    private let token = "/" + UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Upload] = [:]
    private var importing = false

    private final class Upload {
        let connection: NWConnection
        var bytes = Data()
        var length: Int?
        var timeout: DispatchWorkItem?
        var importTask: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    func start(ready: @escaping @MainActor (String?) -> Void,
               receive: @escaping @MainActor (Data) async -> Bool) {
        queue.async {
            do {
                guard let ip = Self.localAddress() else { throw POSIXError(.ENETDOWN) }
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let address = listener.port.map { "http://\(ip):\($0.rawValue)\(self.token)" }
                        Task { @MainActor in ready(address) }
                    case .failed:
                        self.close()
                        Task { @MainActor in ready(nil) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.listener != nil, self.connections.count < 4 else { connection.cancel(); return }
                    let upload = Upload(connection)
                    let key = ObjectIdentifier(upload)
                    let timeout = DispatchWorkItem { [weak self, weak upload] in
                        if let upload { self?.finish(upload) }
                    }
                    upload.timeout = timeout
                    self.connections[key] = upload
                    self.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
                    connection.start(queue: self.queue)
                    self.read(upload, receive: receive)
                }
                listener.start(queue: self.queue)
            } catch {
                Task { @MainActor in ready(nil) }
            }
        }
    }

    func stop() { queue.async { self.close() } }

    private func close() {
        listener?.cancel()
        listener = nil
        for upload in Array(connections.values) { finish(upload) }
    }

    private func finish(_ upload: Upload) {
        upload.timeout?.cancel()
        upload.importTask?.cancel()
        upload.connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(upload))
    }

    private func read(_ upload: Upload, receive: @escaping @MainActor (Data) async -> Bool) {
        upload.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak upload] data, _, complete, error in
            guard let self, let upload else { return }
            if let data { upload.bytes.append(data) }
            if error != nil { self.finish(upload); return }
            if self.consume(upload, receive: receive) { return }
            if complete { self.finish(upload) }
            else { self.read(upload, receive: receive) }
        }
    }

    private func consume(_ upload: Upload, receive: @escaping @MainActor (Data) async -> Bool) -> Bool {
        guard listener != nil else { finish(upload); return true }
        if upload.length == nil {
            let separator = Data([13, 10, 13, 10])
            guard let end = upload.bytes.range(of: separator) else {
                if upload.bytes.count < 8192 { return false }
                reply(upload, "431 Request Header Fields Too Large", "Invalid request.")
                return true
            }
            guard end.lowerBound < 8192,
                  let header = String(data: upload.bytes[..<end.lowerBound], encoding: .utf8) else {
                reply(upload, "400 Bad Request", "Invalid request.")
                return true
            }
            let lines = header.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count == 3, request[1] == token else {
                reply(upload, "404 Not Found", "This upload link is unavailable.")
                return true
            }
            if request[0] == "GET" {
                reply(upload, "200 OK", Self.uploadPage, html: true)
                return true
            }
            let headers = lines.dropFirst().compactMap { line -> (String, String)? in
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (pair[0].lowercased(), pair[1].trimmingCharacters(in: .whitespaces))
            }
            let lengths = headers.filter { $0.0 == "content-length" }
            guard request[0] == "POST", !headers.contains(where: { $0.0 == "transfer-encoding" }),
                  headers.contains(where: { $0 == ("content-type", "application/octet-stream") }),
                  lengths.count == 1, let size = Int(lengths[0].1), size > 0 else {
                reply(upload, "400 Bad Request", "Choose an image and try again.")
                return true
            }
            guard size <= CustomBackground.maximumInputBytes else {
                reply(upload, "413 Content Too Large", "Choose an image smaller than 24 MB.")
                return true
            }
            upload.length = size
            upload.bytes.removeSubrange(..<end.upperBound)
        }

        guard let size = upload.length, upload.bytes.count >= size else { return false }
        guard upload.bytes.count == size, !importing else {
            reply(upload, "409 Conflict", "An upload is already in progress.")
            return true
        }
        importing = true
        let data = upload.bytes
        upload.bytes = Data()
        upload.importTask = Task { @MainActor [weak self, weak upload] in
            guard let self, let upload else { return }
            let accepted = !Task.isCancelled ? await receive(data) : false
            self.queue.async {
                self.importing = false
                guard self.listener != nil, self.connections[ObjectIdentifier(upload)] != nil else { return }
                if accepted {
                    self.listener?.cancel()
                    self.listener = nil
                }
                self.reply(upload, accepted ? "200 OK" : "415 Unsupported Media Type",
                           accepted ? "Your background is set on Apple TV." : "That photo could not be imported. Try a JPEG or PNG.")
            }
        }
        return true
    }

    private func reply(_ upload: Upload, _ status: String, _ text: String, html: Bool = false) {
        let body = Data(text.utf8)
        let mime = html ? "text/html" : "text/plain"
        let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime); charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(csp)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        upload.connection.send(content: response, completion: .contentProcessed { [weak self, weak upload] _ in
            if let upload { self?.finish(upload) }
        })
    }

    private static func localAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var current: UnsafeMutablePointer<ifaddrs>? = addresses
        while let item = current {
            current = item.pointee.ifa_next
            let interface = item.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name).hasPrefix("en"),
                  (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let first = ip >> 24, second = (ip >> 16) & 255
            if first == 10 || (first == 172 && (16...31).contains(second)) ||
               (first == 192 && second == 168) || (first == 169 && second == 254) {
                return [24, 16, 8, 0].map { String((ip >> $0) & 255) }.joined(separator: ".")
            }
        }
        return nil
    }

    private static let uploadPage = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Send a Background Photo</title>
    <style>
      :root { color-scheme:dark; font:17px system-ui; }
      body { display:grid; place-items:center; min-height:90dvh; margin:0; background:#0d1420; color:#eef5fb; }
      main { width:min(28rem,84vw); } h1 { margin-top:0; } p { color:#bdcad5; line-height:1.5; }
      input, button { display:block; font:inherit; margin-block:1rem; max-width:100%; }
      button { padding:.65rem 1.2rem; border:0; border-radius:1.4rem; background:#a3eddc; color:#0a292e; font-weight:650; }
      button:disabled { opacity:.55; }
    </style>
    <main><h1>Send a Background Photo</h1><p>Choose a photo to use in Tool Drive Offline on Apple TV.</p>
    <form><input type="file" accept="image/*" aria-label="Background photo" required><button>Send Photo</button></form>
    <p role="status" aria-live="polite"></p></main>
    <script>
      const form = document.querySelector('form'), input = form.querySelector('input'), button = form.querySelector('button');
      const status = document.querySelector('[role=status]');
      form.onsubmit = async event => {
        event.preventDefault();
        const image = input.files[0];
        if (!image) return;
        if (image.size > 24 * 1024 * 1024) { status.textContent = 'Choose an image smaller than 24 MB.'; return; }
        input.disabled = button.disabled = true;
        status.textContent = 'Sending photo…';
        let added = false;
        try {
          const reply = await fetch(location.pathname, {method:'POST', headers:{'Content-Type':'application/octet-stream'}, body:image});
          status.textContent = await reply.text();
          added = reply.ok;
        } catch { status.textContent = 'Could not reach Apple TV. Check that the upload screen is open and try again.'; }
        if (added) form.hidden = true;
        else input.disabled = button.disabled = false;
      };
    </script></html>
    """
}
