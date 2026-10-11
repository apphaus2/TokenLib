//
//  Transport.swift
//  TokenLib
//
//  HTTP with streaming bodies, small enough to fake in tests. Providers
//  build an HttpRequest and read the body line by line (server-sent events
//  and newline-delimited JSON both arrive that way).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HttpRequest: Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }

    public var bodyJSON: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

/// A handle to cancel an in-flight request.
public protocol Cancellable { func cancel() }

public protocol HttpTransport {
    /// Sends the request; `onStatus` gets the HTTP status once, `onLine` each line of the body as it
    /// arrives (without the newline), `completion` the end (with the whole body when the status is not 2xx).
    @discardableResult
    func stream(_ request: HttpRequest, onStatus: @escaping (Int) -> Void, onLine: @escaping (String) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) -> Cancellable
}

/// Splits a byte stream into lines, holding back an incomplete last line.
public struct LineSplitter {
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Server-sent events: `event:` and `data:` lines, blank line ends an event.
public struct SSEParser {
    public struct Event: Equatable {
        public var name: String?
        public var data: String
    }
    private var name: String?
    private var data: [String] = []
    public init() {}

    /// Feeds one line; returns the event it completed, if any.
    public mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            guard !data.isEmpty else { name = nil; return nil }
            let event = Event(name: name, data: data.joined(separator: "\n"))
            name = nil; data = []
            return event
        }
        if line.hasPrefix(":") { return nil }
        let field: String, value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var v = String(line[line.index(after: colon)...])
            if v.hasPrefix(" ") { v.removeFirst() }
            value = v
        } else {
            field = line; value = ""
        }
        switch field {
        case "event": name = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

/// URLSession based transport; streams the body through a delegate.
public final class URLSessionTransport: NSObject, HttpTransport, URLSessionDataDelegate {
    private var session: URLSession! // set once in init
    private var tasks: [Int: TaskState] = [:]
    private let lock = NSLock()

    private final class TaskState {
        var status = 0
        var splitter = LineSplitter()
        var body = Data()
        let onStatus: (Int) -> Void
        let onLine: (String) -> Void
        let completion: (Result<Void, TokenLibError>) -> Void
        init(onStatus: @escaping (Int) -> Void, onLine: @escaping (String) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) {
            self.onStatus = onStatus; self.onLine = onLine; self.completion = completion
        }
    }

    private struct TaskHandle: Cancellable {
        let task: URLSessionDataTask
        func cancel() { task.cancel() }
    }

    public init(configuration: URLSessionConfiguration = .default) {
        super.init()
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func stream(_ request: HttpRequest, onStatus: @escaping (Int) -> Void, onLine: @escaping (String) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) -> Cancellable {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.httpBody = request.body
        let task = session.dataTask(with: urlRequest)
        lock.lock(); tasks[task.taskIdentifier] = TaskState(onStatus: onStatus, onLine: onLine, completion: completion); lock.unlock()
        task.resume()
        return TaskHandle(task: task)
    }

    private func state(for task: URLSessionTask) -> TaskState? { lock.lock(); defer { lock.unlock() }; return tasks[task.taskIdentifier] }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let state = state(for: dataTask), let http = response as? HTTPURLResponse {
            state.status = http.statusCode
            state.onStatus(http.statusCode)
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        if (200..<300).contains(state.status) {
            for line in state.splitter.append(data) { state.onLine(line) }
        } else {
            state.body.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = tasks.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let state = state else { return }
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { state.completion(.failure(.cancelled)) } else { state.completion(.failure(.transport(error.localizedDescription))) }
            return
        }
        if (200..<300).contains(state.status) {
            if let last = state.splitter.flush() { state.onLine(last) }
            state.completion(.success(()))
        } else {
            state.completion(.failure(.http(status: state.status, body: String(decoding: state.body, as: UTF8.self))))
        }
    }
}
