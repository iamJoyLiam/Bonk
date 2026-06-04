//
//  ServerInfoParserTests.swift
//  BonkTests
//

import XCTest
@testable import Bonk

final class ServerInfoParserTests: XCTestCase {

    func testParseCompleteOutput() {
        let output = """
        hostname=web-server-01
        os=Ubuntu 22.04.3 LTS
        kernel=5.15.0-91-generic
        arch=x86_64
        uptime=up 42 days
        cpu=Intel Xeon E5-2680 v4
        cores=8
        mem=2.1G/16G
        disk=12G/100G
        load=0.15 0.20 0.18
        ip=192.168.1.100
        shell=/bin/bash
        """

        let info = ServerInfoFetcher.parseOutput(output)

        XCTAssertEqual(info.hostname, "web-server-01")
        XCTAssertEqual(info.os, "Ubuntu 22.04.3 LTS")
        XCTAssertEqual(info.kernel, "5.15.0-91-generic")
        XCTAssertEqual(info.architecture, "x86_64")
        XCTAssertEqual(info.uptime, "up 42 days")
        XCTAssertEqual(info.cpuModel, "Intel Xeon E5-2680 v4")
        XCTAssertEqual(info.cpuCores, "8")
        XCTAssertEqual(info.memoryUsed, "2.1G/16G")
        XCTAssertEqual(info.diskUsed, "12G/100G")
        XCTAssertEqual(info.loadAverage, "0.15 0.20 0.18")
        XCTAssertEqual(info.serverIP, "192.168.1.100")
        XCTAssertEqual(info.shell, "/bin/bash")
    }

    func testParsePartialOutput() {
        let output = "hostname=myhost\nos=Debian 12"
        let info = ServerInfoFetcher.parseOutput(output)

        XCTAssertEqual(info.hostname, "myhost")
        XCTAssertEqual(info.os, "Debian 12")
        XCTAssertNil(info.kernel)
        XCTAssertNil(info.cpuModel)
    }

    func testParseEmptyOutput() {
        let info = ServerInfoFetcher.parseOutput("")
        XCTAssertNil(info.hostname)
        XCTAssertNil(info.os)
    }

    func testParseIgnoresEmptyValues() {
        let output = "hostname=test\nip=\nshell=/bin/zsh"
        let info = ServerInfoFetcher.parseOutput(output)

        XCTAssertEqual(info.hostname, "test")
        XCTAssertNil(info.serverIP)  // empty value ignored
        XCTAssertEqual(info.shell, "/bin/zsh")
    }

    func testParseIgnoresMalformedLines() {
        let output = "hostname=test\nno-equals-sign\nshell=/bin/bash"
        let info = ServerInfoFetcher.parseOutput(output)

        XCTAssertEqual(info.hostname, "test")
        XCTAssertEqual(info.shell, "/bin/bash")
    }

    func testParseTrimsWhitespace() {
        let output = "  hostname=  myhost  \n  os= Ubuntu  "
        let info = ServerInfoFetcher.parseOutput(output)

        XCTAssertEqual(info.hostname, "myhost")
        XCTAssertEqual(info.os, "Ubuntu")
    }
}
