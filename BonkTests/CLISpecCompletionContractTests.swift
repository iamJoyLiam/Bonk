//
//  CLISpecCompletionContractTests.swift
//  BonkTests
//
//  P1 Completion Pipeline & CLI Spec Contract Tests.
//

import Testing
import Foundation
@testable import Bonk

@Suite("P1 Completion Pipeline & CLI Spec Contract Tests")
@MainActor
struct CLISpecCompletionContractTests {

    @Test("1. CLI Spec provides immediate deterministic subcommands without LLM")
    func testCLISpecProvidesDeterministicSubcommands() {
        let registry = CLISpecRegistry.shared
        let candidates = registry.candidates(for: "docker ")

        #expect(!candidates.isEmpty)
        let subcommands = candidates.map { $0.suggestion.fullText ?? "" }
        #expect(subcommands.contains("docker ps"))
        #expect(subcommands.contains("docker images"))
        #expect(subcommands.contains("docker run"))
        #expect(candidates.allSatisfy { $0.authority == .deterministic })
        #expect(candidates.allSatisfy { $0.source == "cliSpec" })
    }

    @Test("2. CLI Spec hard-filters matching subcommands on partial prefix")
    func testCLISpecPrefixFiltering() {
        let registry = CLISpecRegistry.shared

        // docker im -> docker images
        let dockerCandidates = registry.candidates(for: "docker im")
        #expect(!dockerCandidates.isEmpty)
        #expect(dockerCandidates.first?.suggestion.fullText == "docker images")
        #expect(dockerCandidates.first?.suggestion.text == "ages")

        // git st -> status, stash
        let gitCandidates = registry.candidates(for: "git st")
        #expect(!gitCandidates.isEmpty)
        let gitNames = gitCandidates.map { $0.suggestion.fullText ?? "" }
        #expect(gitNames.contains("git status"))
        #expect(gitNames.contains("git stash"))
        #expect(!gitNames.contains("git commit"))
    }

    @Test("3. CLI Spec provides common flags after subcommand")
    func testCLISpecFlagsCompletion() {
        let registry = CLISpecRegistry.shared
        let flags = registry.candidates(for: "docker ps -")

        #expect(!flags.isEmpty)
        let flagTexts = flags.map { $0.suggestion.fullText ?? "" }
        #expect(flagTexts.contains(where: { $0.contains("-a") }))
    }

    @Test("4. Candidate Pool mixes CLI Spec with user history")
    func testCandidatePoolCombinesSpecAndHistory() {
        let pool = CandidatePool()
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker ",
            recentCommands: ["docker ps -a", "docker run -d redis"],
            recentOutput: ""
        )

        let candidates = pool.buildCandidates(
            typed: "docker ",
            snapshot: snapshot,
            cache: nil,
            cacheKey: nil,
            isRejected: { _ in false }
        )

        #expect(!candidates.isEmpty)
        let fullCommands = candidates.compactMap { $0.suggestion.fullText }

        // Must contain history entries
        #expect(fullCommands.contains("docker run -d redis"))
        // Must also contain CLI spec subcommands
        #expect(fullCommands.contains("docker ps"))
        #expect(fullCommands.contains("docker images"))
    }

    @Test("5. Hard Filter rejects non-matching candidates")
    func testCandidatePoolHardFilterRejectsMismatches() {
        let pool = CandidatePool()
        let snapshot = CommandContextSnapshot(
            inputBuffer: "git com",
            recentCommands: ["docker run nginx", "ls -la"],
            recentOutput: ""
        )

        let candidates = pool.buildCandidates(
            typed: "git com",
            snapshot: snapshot,
            cache: nil,
            cacheKey: nil,
            isRejected: { _ in false }
        )

        // Only git commit should survive
        let fullCommands = candidates.compactMap { $0.suggestion.fullText }
        #expect(fullCommands.contains("git commit"))
        #expect(!fullCommands.contains("docker run nginx"))
        #expect(!fullCommands.contains("ls -la"))
    }

    @Test("6. Completion works 100% reliably when LLM is unavailable")
    func testLocalRankingWorksWhenLLMUnavailable() {
        let pipeline = InlineSuggestionPipeline()
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker ",
            recentCommands: [],
            recentOutput: ""
        )

        pipeline.request(snapshot: snapshot)

        // Deterministic candidate appears immediately
        #expect(pipeline.suggestion != nil)
        #expect(!pipeline.ranked.isEmpty)
        #expect(pipeline.ranked.first?.1.fullText?.hasPrefix("docker ") == true)
    }

    @Test("7. AI Reranker NEVER invents new commands outside the candidate pool")
    func testAIRerankerNeverInventsNewCommands() async {
        let reranker = AIReranker()
        let originalPool = [
            CommandCandidate(
                source: "cliSpec",
                authority: .deterministic,
                suggestion: Suggestion(text: "ps", displayText: "ps", fullText: "docker ps"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "cliSpec",
                authority: .deterministic,
                suggestion: Suggestion(text: "images", displayText: "images", fullText: "docker images"),
                rawScore: 85.0
            )
        ]

        let snapshot = CommandContextSnapshot(inputBuffer: "docker ")

        // When LLM provider is nil or unavailable, returns original pool unchanged
        let reranked = await reranker.rerank(
            candidates: originalPool,
            typed: "docker ",
            snapshot: snapshot,
            provider: nil,
            apiKey: nil
        )

        #expect(reranked.count == 2)
        #expect(reranked.map { $0.suggestion.fullText } == ["docker ps", "docker images"])
    }

    @Test("8. Candidate Pool normalizes multiple spaces and deduplicates (no 'docker ps' vs 'docker   ps')")
    func testCandidatePoolDeduplicatesMultipleSpaces() {
        let pool = CandidatePool()
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker ",
            recentCommands: ["docker   ps", "docker ps"],
            recentOutput: ""
        )

        let candidates = pool.buildCandidates(
            typed: "docker ",
            snapshot: snapshot,
            cache: nil,
            cacheKey: nil,
            isRejected: { _ in false }
        )

        let dockerPsMatches = candidates.filter {
            let text = ($0.suggestion.fullText ?? $0.suggestion.text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text == "docker ps"
        }
        #expect(dockerPsMatches.count == 1, "Duplicate 'docker ps' with irregular spacing must be deduplicated to 1")
    }

    @Test("9. Expanded DevOps CLI Specs provide instant subcommands for ufw, apt, rsync, ps, tail")
    func testExpandedDevOpsCLISpecs() {
        let registry = CLISpecRegistry.shared

        let ufwCandidates = registry.candidates(for: "ufw ")
        #expect(!ufwCandidates.isEmpty)
        let ufwNames = ufwCandidates.map { $0.suggestion.fullText ?? "" }
        #expect(ufwNames.contains("ufw status"))
        #expect(ufwNames.contains("ufw allow"))

        let aptCandidates = registry.candidates(for: "apt ")
        #expect(!aptCandidates.isEmpty)
        let aptNames = aptCandidates.map { $0.suggestion.fullText ?? "" }
        #expect(aptNames.contains("apt update"))
        #expect(aptNames.contains("apt install"))

        let rsyncCandidates = registry.candidates(for: "rsync ")
        #expect(!rsyncCandidates.isEmpty)
        let rsyncNames = rsyncCandidates.map { $0.suggestion.fullText ?? "" }
        #expect(rsyncNames.contains("rsync -avz"))

        let psCandidates = registry.candidates(for: "ps ")
        #expect(!psCandidates.isEmpty)
        let psNames = psCandidates.map { $0.suggestion.fullText ?? "" }
        #expect(psNames.contains("ps aux"))
    }

    @Test("10. ShellCommandParser separates multiple commands for individual execution")
    func testShellCommandParser() {
        let multiScript = """
        # Step 1: check containers
        docker ps

        # Step 2: view logs
        docker logs -fn 200 sentinel-syslog

        # Step 3: restart
        docker restart sentinel-syslog
        """

        let parsed = ShellCommandParser.parse(code: multiScript)
        let commands = parsed.filter(\.isCommand)
        #expect(commands.count == 3)
        #expect(commands[0].commandText == "docker ps")
        #expect(commands[1].commandText == "docker logs -fn 200 sentinel-syslog")
        #expect(commands[2].commandText == "docker restart sentinel-syslog")
        #expect(commands[0].commentLines.contains("# Step 1: check containers"))
    }
}
