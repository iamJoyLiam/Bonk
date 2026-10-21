//
//  StubHTTPURLProtocol.swift
//  BonkTests
//
//  Intercepts a provider's URLSession traffic, records what was sent, and
//  answers with a canned body.
//
//  A `URLProtocol` is the right seam for this: it exercises the provider's
//  real request path — the URL, the headers, the body that actually went
//  out — without a network and without a port.
//
//  State is keyed by request host, not shared. Swift Testing runs tests in
//  parallel, and one global slot would mean each test wiped the request
//  the next one was about to assert on.
//

import Foundation
import os

final class StubHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedRequest {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data
    }

    private struct Entry {
        var responseBody = ""
        var lastRequest: CapturedRequest?
    }

    private static let state = OSAllocatedUnfairLock<[String: Entry]>(uncheckedState: [:])

    /// Forget the recorded request and canned reply for one host.
    ///
    /// Scoped to the host on purpose: Swift Testing runs tests in parallel,
    /// and a global reset would wipe the request another test is about to
    /// assert on.
    static func reset(for host: String) {
        state.withLock { $0[host] = nil }
    }

    /// The reply requests to this host will get.
    static func setResponse(_ body: String, for host: String) {
        state.withLock { $0[host, default: Entry()].responseBody = body }
    }

    /// What the last intercepted request to this host looked like.
    static func lastRequest(for host: String) -> CapturedRequest? {
        state.withLock { $0[host]?.lastRequest }
    }

    /// A session whose traffic is intercepted here.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let outgoing = request
        let target = client
        let host = outgoing.url?.host ?? ""
        var headers: [String: String] = [:]
        for (key, value) in outgoing.allHTTPHeaderFields ?? [:] {
            headers[key.lowercased()] = value
        }
        let captured = CapturedRequest(
            url: outgoing.url ?? URL(string: "about:blank")!,
            method: outgoing.httpMethod ?? "GET",
            headers: headers,
            body: Self.bodyData(of: outgoing)
        )
        let payload = Self.state.withLock { state -> Data in
            var entry = state[host] ?? Entry()
            entry.lastRequest = captured
            state[host] = entry
            return Data(entry.responseBody.utf8)
        }
        let response = HTTPURLResponse(
            url: outgoing.url ?? URL(string: "about:blank")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        target?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        target?.urlProtocol(self, didLoad: payload)
        target?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The request body.
    ///
    /// A `URLProtocol` does not see `httpBody`: the loading system has
    /// already moved it into `httpBodyStream`. Reading only `httpBody` here
    /// records an empty body and every assertion about the request passes
    /// vacuously.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
