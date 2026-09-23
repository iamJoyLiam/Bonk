import Testing
@testable import Bonk

/// Layered fetching: static once, fast every poll, heavy on slow cadence.
/// Overlay order is static <- fast <- heavy; a failed layer contributes
/// nothing so last-known values survive.
@Suite("ServerInfo Layering Tests")
struct ServerInfoLayeringTests {
    @Test("overlay merges static, fast, and heavy layers")
    func overlayMergesLayers() {
        var staticInfo = ServerInfo()
        staticInfo.hostname = "web-01"
        staticInfo.cpuModel = "Xeon"
        staticInfo.memTotalBytes = 16 * 1_073_741_824

        var fast = ServerInfo()
        fast.cpuUsagePercent = 42
        fast.memUsedBytes = 4 * 1_073_741_824
        fast.uptimeSeconds = 3_600

        var heavy = ServerInfo()
        heavy.topProcesses = "12.3|bash;"
        heavy.listenPorts = "22,80,"

        let merged = staticInfo.overlaying(fast).overlaying(heavy)
        #expect(merged.hostname == "web-01")
        #expect(merged.cpuModel == "Xeon")
        #expect(merged.memTotalBytes == UInt64(16 * 1_073_741_824))
        #expect(merged.cpuUsagePercent == 42)
        #expect(merged.memUsedBytes == UInt64(4 * 1_073_741_824))
        #expect(merged.uptimeSeconds == 3_600)
        #expect(merged.topProcesses == "12.3|bash;")
        #expect(merged.listenPorts == "22,80,")
    }

    @Test("failed layer preserves last-known values")
    func overlayFailedLayerKeepsBase() {
        var base = ServerInfo()
        base.hostname = "web-01"
        base.cpuUsagePercent = 42
        base.topProcesses = "12.3|bash;"
        let merged = base.overlaying(ServerInfo()).overlaying(ServerInfo())
        #expect(merged.hostname == "web-01")
        #expect(merged.cpuUsagePercent == 42)
        #expect(merged.topProcesses == "12.3|bash;")
    }

    @Test("rates are never overlaid")
    func overlayNeverTouchesRates() {
        var base = ServerInfo()
        base.networkRXRateBps = 100
        var other = ServerInfo()
        other.networkRXRateBps = 200
        #expect(base.overlaying(other).networkRXRateBps == 100)
    }

    @Test("fast script feeds rings without heavy commands")
    func fastScriptScope() {
        let fast = ServerInfoFetcher.fastScript
        #expect(fast.contains("cpu_percent="))
        #expect(fast.contains("mem_used_bytes="))
        #expect(fast.contains("disk_used_bytes="))
        #expect(fast.contains("net_rx_bytes="))
        #expect(!fast.contains("top_procs="))
        #expect(!fast.contains("listen_ports="))
        #expect(!fast.contains("lscpu"))
        #expect(!fast.contains("sw_vers"))
    }

    @Test("static script carries facts, never samples")
    func staticScriptScope() {
        let staticScript = ServerInfoFetcher.staticScript
        #expect(staticScript.contains("hostname="))
        #expect(staticScript.contains("lscpu"))
        #expect(staticScript.contains("cores="))
        #expect(staticScript.contains("mem_total_bytes="))
        #expect(staticScript.contains("disk_total_bytes="))
        #expect(!staticScript.contains("cpu_percent="))
        #expect(!staticScript.contains("sleep 1"))
        #expect(!staticScript.contains("top_procs="))
        #expect(!staticScript.contains("listen_ports="))
    }

    @Test("heavy script carries only detail commands")
    func heavyScriptScope() {
        let heavy = ServerInfoFetcher.heavyScript
        #expect(heavy.contains("top_procs="))
        #expect(heavy.contains("listen_ports="))
        #expect(!heavy.contains("cpu_percent="))
        #expect(!heavy.contains("sleep 1"))
    }
}
