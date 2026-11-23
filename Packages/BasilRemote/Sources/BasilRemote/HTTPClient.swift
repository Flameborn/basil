import BasilCore
import BasilVFS
import Foundation
import Security
import Synchronization

/// Where one HTTP connection (WebDAV, S3) goes.
struct HTTPEndpoint: Sendable {
    var service: ProviderID
    var secure: Bool
    var host: String
    var port: Int
    var defaultPort: Int
    /// Empty: no login.
    var user: String

    /// "example.com", or "example.com:8443" off the default port.
    var hostAndPort: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? name : "\(name):\(port)"
    }

    /// "erion@example.com", or the host alone without a login.
    var account: String { user.isEmpty ? hostAndPort : "\(user)@\(hostAndPort)" }

    /// "https://example.com:8443", without a path.
    var origin: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return (secure ? "https://" : "http://") + name + (port == defaultPort ? "" : ":\(port)")
    }
}

/// One answer from the server: status, headers (names in lower case) and body.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(_ response: HTTPURLResponse, body: Data) {
        status = response.statusCode
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var isSuccess: Bool { (200..<300).contains(status) }

    /// The server's own words for an error: SabreDAV's (Nextcloud) `<s:message>`, Apache's
    /// `<D:responsedescription>`, or the status in words.
    var problem: String {
        let text = String(decoding: body.prefix(64 << 10), as: UTF8.self)
        for tag in ["s:message", "D:responsedescription", "d:responsedescription"] {
            if let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) {
                let message = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty { return "\(message) (HTTP \(status))" }
            }
        }
        return "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
    }
}

/// The server's certificate is not trusted by the system nor accepted for this connection.
struct UntrustedCertificate: Error {
    var chain: [Data]
}

/// The server asked for a login (401) that Basil did not have or that it refused.
struct HTTPUnauthorized: Error {}

/// HTTP for one WebDAV or S3 connection, through its own URLSession (ephemeral: no cache, cookies only
/// in memory, no stored credentials). Logins are answered from the password given to the
/// connection (Basic, Digest; after the first Basic challenge every request carries it, so
/// streamed uploads are never challenged). TLS certificates the system does not trust are
/// refused unless the connector accepted that certificate (`UntrustedCertificate` tells it).
final class HTTPClient: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let endpoint: HTTPEndpoint
    private var session: URLSession!

    private struct State {
        var password: String?
        /// The server asked for Basic: send it with every request.
        var basic = false
        var acceptedCertificate: Data?
        var untrustedChain: [Data]?
        /// Per-task delegates of downloads, by task identifier.
        var downloads: [Int: HTTPDownload] = [:]
    }

    private let state = Mutex(State())

    init(endpoint: HTTPEndpoint) {
        self.endpoint = endpoint
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = ["User-Agent": "Basil"]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    var password: String? {
        get { state.withLock { $0.password } }
        set { state.withLock { $0.password = newValue } }
    }

    func accept(certificate digest: Data?) { state.withLock { $0.acceptedCertificate = digest } }
    var acceptedCertificate: Data? { state.withLock { $0.acceptedCertificate } }

    func close() { session.invalidateAndCancel() }

    // MARK: Requests

    /// A request for `url`, with the login when the server takes Basic.
    func request(_ method: String, _ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (basic, password) = state.withLock { ($0.basic, $0.password) }
        if basic, let password, !endpoint.user.isEmpty {
            let token = Data("\(endpoint.user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends a request with an optional body and returns the whole answer. `retry`: the request
    /// may be sent again after a network error or a busy server (429, 502, 503, 504), up to four
    /// times, waiting longer each time. Throws `UntrustedCertificate` and `HTTPUnauthorized`
    /// (401) for the connector; other statuses are returned.
    func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
              file: URL? = nil, retry: Bool = true) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let request = request(method, url, headers: headers)
            let result: (Data, URLResponse)
            do {
                if let file {
                    result = try await session.upload(for: request, fromFile: file)
                } else if let body {
                    result = try await session.upload(for: request, from: body)
                } else {
                    result = try await session.data(for: request)
                }
            } catch {
                let mapped = mapped(error)
                if retry, attempt < 4, mapped is URLError {
                    try await Task.sleep(for: .seconds(Double(1 << (attempt - 1))))
                    continue
                }
                throw describe(mapped, method: method)
            }
            guard let http = result.1 as? HTTPURLResponse else {
                throw VFSError.failed("\(endpoint.hostAndPort) did not answer over HTTP")
            }
            let response = HTTPResponse(http, body: result.0)
            if response.status == 401 { throw HTTPUnauthorized() }
            if retry, attempt < 4, [429, 502, 503, 504].contains(response.status) {
                let wait = response.header("Retry-After").flatMap(Double.init) ?? Double(1 << (attempt - 1))
                try await Task.sleep(for: .seconds(min(wait, 30)))
                continue
            }
            return response
        }
    }

    /// Turns a refused certificate into `UntrustedCertificate`; leaves other errors as they are.
    func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            let chain = state.withLock { s -> [Data]? in
                defer { s.untrustedChain = nil }
                return s.untrustedChain
            }
            if let chain, [.cancelled, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                           .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                           .secureConnectionFailed].contains(urlError.code) {
                return UntrustedCertificate(chain: chain)
            }
            if urlError.code == .cancelled, Task.isCancelled { return CancellationError() }
        }
        return error
    }

    /// An error in words for the user.
    func describe(_ error: Error, method: String) -> Error {
        if error is UntrustedCertificate || error is CancellationError || error is VFSError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return VFSError.failed("\(endpoint.host) was not found")
            case .cannotConnectToHost:
                return VFSError.failed("\(endpoint.hostAndPort) refused the connection")
            case .timedOut:
                return VFSError.failed("\(endpoint.hostAndPort) did not answer in time")
            case .notConnectedToInternet:
                return VFSError.failed("This Mac is not connected to a network")
            case .networkConnectionLost:
                return VFSError.failed("The connection to \(endpoint.hostAndPort) was lost")
            case .appTransportSecurityRequiresSecureConnection:
                return VFSError.failed("macOS refused a plain HTTP connection to \(endpoint.hostAndPort)")
            default:
                return VFSError.failed("\(endpoint.hostAndPort): \(urlError.localizedDescription)")
            }
        }
        return VFSError.failed("\(endpoint.hostAndPort): \(error.localizedDescription)")
    }

    /// Starts a download of `url` from byte `offset` on ("Range: bytes=offset-"), delivered as it
    /// arrives (`HTTPDownload`).
    func download(_ url: URL, from offset: Int64, headers: [String: String] = [:]) -> HTTPDownload {
        var headers = headers
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        var request = request("GET", url, headers: headers)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        let download = HTTPDownload(task: task, client: self)
        state.withLock { $0.downloads[task.taskIdentifier] = download }
        task.resume()
        return download
    }

    /// Starts an upload whose body is written as it comes (chunked transfer encoding).
    func streamedUpload(_ method: String, _ url: URL, headers: [String: String]) -> HTTPStreamUpload {
        HTTPStreamUpload(client: self, request: request(method, url, headers: headers))
    }

    /// Runs a request whose body is a stream; used by `HTTPStreamUpload`.
    func perform(streamed request: URLRequest) async throws -> HTTPResponse {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw describe(mapped(error), method: request.httpMethod ?? "PUT")
        }
        guard let http = response as? HTTPURLResponse else {
            throw VFSError.failed("\(endpoint.hostAndPort) did not answer over HTTP")
        }
        return HTTPResponse(http, body: data)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = answer(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = answer(challenge)
        completionHandler(disposition, credential)
    }

    private func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            let chain = ((SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []).map { SecCertificateCopyData($0) as Data }
            if CertificateTrust.evaluate(chain, host: space.host).trusted { return (.performDefaultHandling, nil) }
            if let leaf = chain.first, let accepted = acceptedCertificate, CertificateTrust.fingerprint(leaf) == accepted {
                return (.useCredential, URLCredential(trust: trust))
            }
            state.withLock { $0.untrustedChain = chain }
            return (.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            let password = state.withLock { s -> String? in
                if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic { s.basic = true }
                return s.password
            }
            // Without a password, or when it was just refused, the 401 comes back to the caller.
            guard let password, !endpoint.user.isEmpty, challenge.previousFailureCount == 0 else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(user: endpoint.user, password: password, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    /// A streamed body cannot be sent twice.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(nil)
    }

    /// Redirects: followed for reading (GET, PROPFIND), but never for changes, whose target
    /// must be the one asked for.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let method = task.originalRequest?.httpMethod ?? "GET"
        guard ["GET", "HEAD", "PROPFIND"].contains(method), request.url?.host == task.originalRequest?.url?.host else {
            return completionHandler(nil)
        }
        var next = request
        next.httpMethod = method
        if let original = task.originalRequest {
            for (name, value) in original.allHTTPHeaderFields ?? [:] { next.setValue(value, forHTTPHeaderField: name) }
            next.httpBody = original.httpBody
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        download(for: dataTask)?.received(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        download(for: dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let download = state.withLock { $0.downloads.removeValue(forKey: task.taskIdentifier) }
        download?.finished(error.map { mapped($0) })
    }

    private func download(for task: URLSessionTask) -> HTTPDownload? {
        state.withLock { $0.downloads[task.taskIdentifier] }
    }
}

/// A GET whose body is handed out as it arrives. The task is suspended while more than
/// `limit` bytes wait, so a slow reader never piles up a whole file in memory.
final class HTTPDownload: @unchecked Sendable {
    static let limit = 16 << 20

    private struct State {
        var response: HTTPURLResponse?
        var buffer = Data()
        var done = false
        var error: Error?
        var suspended = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    let task: URLSessionDataTask
    private let client: HTTPClient

    init(task: URLSessionDataTask, client: HTTPClient) {
        self.task = task
        self.client = client
    }

    func received(_ response: URLResponse) {
        wake { $0.response = response as? HTTPURLResponse }
    }

    func received(_ data: Data) {
        wake { s in
            s.buffer.append(data)
            if s.buffer.count > Self.limit, !s.suspended {
                s.suspended = true
                task.suspend()
            }
        }
    }

    func finished(_ error: Error?) {
        wake { s in
            s.done = true
            s.error = error
        }
    }

    private func wake(_ change: (inout State) -> Void) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            change(&s)
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until `ready` holds for the state (checked again after every change).
    private func wait(until ready: @escaping @Sendable (State) -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            if state.withLock({ ready($0) }) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let met = state.withLock { s -> Bool in
                    if ready(s) { return true }
                    s.waiters.append(continuation)
                    return false
                }
                if met { continuation.resume() }
            }
        }
    }

    /// The response's status and headers, once they arrived.
    func response() async throws -> HTTPResponse {
        try await wait { $0.response != nil || $0.done }
        let (response, error) = state.withLock { ($0.response, $0.error) }
        if let response { return HTTPResponse(response, body: Data()) }
        throw client.describe(error ?? VFSError.failed("No answer"), method: "GET")
    }

    /// Up to `count` bytes of the body; fewer only at its end.
    func read(_ count: Int) async throws -> Data {
        try await wait { $0.buffer.count >= count || $0.done }
        let (bytes, error, resume) = state.withLock { s -> (Data, Error?, Bool) in
            let take = min(count, s.buffer.count)
            let bytes = s.buffer.prefix(take)
            s.buffer.removeFirst(take)
            var resume = false
            if s.suspended, s.buffer.count < Self.limit / 2 {
                s.suspended = false
                resume = true
            }
            return (Data(bytes), s.buffer.isEmpty && s.done ? s.error : nil, resume)
        }
        if resume { task.resume() }
        // Bytes that arrived before a failure are handed out first; the next read throws.
        if bytes.isEmpty, count > 0, let error { throw client.describe(error, method: "GET") }
        return bytes
    }

    /// The rest of the body (an error page).
    func rest() async throws -> Data {
        try await wait { $0.done || $0.buffer.count > 64 << 10 }
        return state.withLock { s in
            defer { s.buffer = Data() }
            return s.buffer
        }
    }

    func cancel() {
        task.cancel()
        wake { $0.done = true }
    }
}

/// An upload whose body is written while it is sent (a bound stream pair; the URL loading
/// system reads one end, `write` fills the other on its own dispatch queue, never on the
/// cooperative pool). The server's answer comes from `finish`.
final class HTTPStreamUpload: @unchecked Sendable {
    private let output: OutputStream
    private let task: Task<HTTPResponse, Error>
    private let queue = DispatchQueue(label: "Basil HTTP upload")
    private let ended = Flag()

    struct Ended: Error {}

    /// Set once the request has finished.
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    init(client: HTTPClient, request: URLRequest) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 256 << 10, inputStream: &input, outputStream: &output)
        self.output = output!
        self.output.open()
        var request = request
        request.httpBodyStream = input
        let ended = ended
        task = Task {
            defer { ended.set() }
            return try await client.perform(streamed: request)
        }
    }

    /// Writes bytes into the body. Throws `Ended` when the server answered before the body was
    /// complete (an error, which `finish` returns).
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try blockingWrite(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func blockingWrite(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                if ended.isSet { throw Ended() }
                if output.hasSpaceAvailable {
                    let count = output.write(base + offset, maxLength: raw.count - offset)
                    if count < 0 { throw Ended() }
                    offset += count
                } else {
                    usleep(500)
                }
            }
        }
    }

    /// Ends the body and returns the server's answer.
    func finish() async throws -> HTTPResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) let output = output
            queue.async {
                output.close()
                continuation.resume()
            }
        }
        return try await task.value
    }

    /// The server's answer after `write` threw `Ended`.
    func answer() async throws -> HTTPResponse { try await task.value }

    func cancel() {
        task.cancel()
        nonisolated(unsafe) let output = output
        queue.async { output.close() }
    }
}

/// A file being read over HTTP: one GET from the asked offset on, delivered as it arrives and
/// started again at another offset when the caller jumps. A server that ignores ranges sends the
/// whole file, and the bytes before the offset are dropped.
actor HTTPReadFile: ReadableFile {
    let name: String
    /// Starts a GET from an offset (0: the whole file).
    let start: @Sendable (Int64) -> HTTPDownload
    /// The file's size on the server now, or nil.
    let currentSize: @Sendable () async -> Int64?
    /// A refused GET in VFS terms.
    let failure: @Sendable (HTTPResponse) -> Error
    private var download: HTTPDownload?
    private var position: Int64 = 0
    private var atEnd = false

    init(name: String, start: @escaping @Sendable (Int64) -> HTTPDownload,
         currentSize: @escaping @Sendable () async -> Int64?, failure: @escaping @Sendable (HTTPResponse) -> Error) {
        self.name = name
        self.start = start
        self.currentSize = currentSize
        self.failure = failure
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        if atEnd, offset >= position { return Data() }
        if download == nil || offset != position {
            try await begin(at: offset)
            if atEnd { return Data() }
        }
        guard let download else { return Data() }
        let bytes: Data
        do { bytes = try await download.read(count) } catch {
            stop()
            // A server sends the length the file had when the transfer began and drops the
            // connection when it was cut short meanwhile. When the file is no longer than what
            // arrived, that was its end; the copy engine sees the changed size and reads again.
            if let size = await currentSize(), size <= position {
                atEnd = true
                return Data()
            }
            throw VFSError.failed("Reading \(name) failed: \(error.localizedDescription)")
        }
        position += Int64(bytes.count)
        if bytes.count < count {
            atEnd = true
            self.download = nil
        }
        return bytes
    }

    private func begin(at offset: Int64) async throws {
        stop()
        atEnd = false
        let download = start(offset)
        let response: HTTPResponse
        do { response = try await download.response() } catch {
            download.cancel()
            throw error is VFSError ? error : VFSError.failed("Reading \(name) failed: \(error.localizedDescription)")
        }
        switch response.status {
        case 206:
            position = offset
        case 200:
            // The whole file: skip to the offset.
            position = 0
            var skip = offset
            while skip > 0 {
                let bytes = try await download.read(Int(min(skip, 1 << 20)))
                if bytes.isEmpty { break }
                skip -= Int64(bytes.count)
                position += Int64(bytes.count)
            }
            if position < offset {
                atEnd = true
                download.cancel()
                return
            }
        case 416:
            // At or past the end.
            position = offset
            atEnd = true
            download.cancel()
            return
        default:
            let body = (try? await download.rest()) ?? Data()
            download.cancel()
            throw failure(HTTPResponse(status: response.status, headers: response.headers, body: body))
        }
        self.download = download
    }

    private func stop() {
        download?.cancel()
        download = nil
    }

    func close() async { stop() }
}
