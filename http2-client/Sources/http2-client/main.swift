//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import NIOHTTP2
import NIOOpenSSL
import Foundation

/// Fires off a GET request when our stream is active and collects all response parts into a promise.
///
/// - warning: This will read the whole response into memory and delivers it into a promise.
final class SendRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    
    private let responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>
    private var responsePartAccumulator: [HTTPClientResponsePart] = []
    private let host: String
    private let compoundRequest: HTTPRequest
    
    init(host: String, request: HTTPRequest, responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>) {
        self.responseReceivedPromise = responseReceivedPromise
        self.host = host
        self.compoundRequest = request
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        assert(ctx.channel.parent!.isActive)
        var headers = HTTPHeaders(self.compoundRequest.headers)
        headers.add(name: "Host", value: self.host)
        var reqHead = HTTPRequestHead(version: self.compoundRequest.version,
                                      method: self.compoundRequest.method,
                                      uri: self.compoundRequest.target)
        reqHead.headers = headers
        if let body = self.compoundRequest.body {
            var buffer = ctx.channel.allocator.buffer(capacity: body.count)
            buffer.write(bytes: body)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        ctx.write(self.wrapOutboundOut(.head(reqHead)), promise: nil)
        ctx.writeAndFlush(self.wrapOutboundOut(.end(self.compoundRequest.trailers.map(HTTPHeaders.init))), promise: nil)
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let resPart = self.unwrapInboundIn(data)
        self.responsePartAccumulator.append(resPart)
        if case .end = resPart {
            self.responseReceivedPromise.succeed(result: self.responsePartAccumulator)
        }
    }
}

/// Creates a new HTTP/2 stream when our channel is active and adds the `SendRequestHandler` so a request is sent.
final class CreateRequestStreamHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    private let multiplexer: HTTP2StreamMultiplexer
    private let responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>
    private let host: String
    private let uri: String
    
    init(host: String, uri: String, multiplexer: HTTP2StreamMultiplexer, responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>) {
        self.multiplexer = multiplexer
        self.responseReceivedPromise = responseReceivedPromise
        self.host = host
        self.uri = uri
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        func requestStreamInitializer(channel: Channel, streamID: HTTP2StreamID) -> EventLoopFuture<Void> {
            return channel.pipeline.addHandlers([HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https),
                                                 SendRequestHandler(host: self.host,
                                                                    request: .init(method: .GET,
                                                                                   target: self.uri,
                                                                                   version: .init(major: 2, minor: 0),
                                                                                   headers: [],
                                                                                   body: nil,
                                                                                   trailers: nil),
                                                                    responseReceivedPromise: self.responseReceivedPromise)],
                                                first: false)
        }

        self.multiplexer.createStreamChannel(promise: nil, requestStreamInitializer)
    }
}

/// Collects any errors in the root stream, forwards them to a promise and closes the whole network connection.
final class CollectErrorsAndCloseStreamHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    private let responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>
    
    init(responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]>) {
        self.responseReceivedPromise = responseReceivedPromise
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        self.responseReceivedPromise.fail(error: error)
        ctx.close(promise: nil)
    }
}

let sslContext = try SSLContext(configuration: TLSConfiguration.forClient(applicationProtocols: ["h2"]))

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let responseReceivedPromise: EventLoopPromise<[HTTPClientResponsePart]> = group.next().newPromise()
var verbose = false
var args = ArraySlice(CommandLine.arguments)

func usage() {
    print("Usage: http2-client [-v] https://host:port/path")
    print()
    print("OPTIONS:")
    print("     -v: verbose operation (print response code, headers, etc.)")
}

if case .some(let arg) = args.dropFirst().first, arg.starts(with: "-") {
    switch arg {
    case "-v":
        verbose = true
        args = args.dropFirst()
    default:
        usage()
        exit(1)
    }
}

guard let url = args.dropFirst().first.flatMap(URL.init(string:)) else {
    usage()
    exit(1)
}
guard let host = url.host else {
    print("ERROR: URL '\(url)' does not have a hostname which is required")
    exit(1)
}
guard url.scheme == "https" else {
    print("ERROR: URL '\(url)' is not https but that's required")
    exit(1)
}

let uri = url.absoluteURL.path == "" ? "/" : url.absoluteURL.path
let port = url.port ?? 443
let bootstrap = ClientBootstrap(group: group)
    .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .channelInitializer { channel in
        let sslHandler = try! OpenSSLClientHandler(context: sslContext, serverHostname: host)
        let http2Parser = HTTP2Parser(mode: .client)
        let http2Multiplexer = HTTP2StreamMultiplexer()
        return channel.pipeline.addHandlers([sslHandler,
                                             http2Parser,
                                             http2Multiplexer,
                                             CreateRequestStreamHandler(host: host,
                                                                        uri: uri,
                                                                        multiplexer: http2Multiplexer,
                                                                        responseReceivedPromise: responseReceivedPromise),
                                             CollectErrorsAndCloseStreamHandler(responseReceivedPromise: responseReceivedPromise)],
                                            first: false).map { return () }
}

defer {
    try! group.syncShutdownGracefully()
}

do {
    let channel = try bootstrap.connect(host: host, port: port).wait()
    if verbose {
        print("* Connected to \(host) (\(channel.remoteAddress!)")
    }
    try! responseReceivedPromise.futureResult.map { responseParts in
        for part in responseParts {
            switch part {
            case .head(let resHead):
                if verbose {
                    print("< HTTP/\(resHead.version.major).\(resHead.version.minor) \(resHead.status.code)")
                    for header in resHead.headers {
                        print("< \(header.name): \(header.value)")
                    }
                }
            case .body(let buffer):
                let written = buffer.withUnsafeReadableBytes { ptr in
                    write(STDOUT_FILENO, ptr.baseAddress, ptr.count)
                }
                precondition(written == buffer.readableBytes) // technically, write could write short ;)
            case .end(_):
                if verbose {
                    print("* Response fully received")
                }
            }
        }
    }.mapIfError { error in
        print("ERROR: \(error)")
        exit(1)
    }.wait()
    exit(0)
} catch {
    print("ERROR: \(error)")
}
