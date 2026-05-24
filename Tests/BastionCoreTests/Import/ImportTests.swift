import Testing
import Foundation
@testable import BastionCore

@Suite("ShellTokenizer")
struct ShellTokenizerTests {
    let tokenizer = ShellTokenizer()

    @Test func basicTokenization() throws {
        let tokens = try tokenizer.tokenize("ssh user@host -p 2222")
        #expect(tokens == ["ssh", "user@host", "-p", "2222"])
    }

    @Test func handlesDoubleQuotes() throws {
        let tokens = try tokenizer.tokenize(#"rsync -e "ssh -p 2222" file host:path"#)
        #expect(tokens == ["rsync", "-e", "ssh -p 2222", "file", "host:path"])
    }

    @Test func handlesSingleQuotes() throws {
        let tokens = try tokenizer.tokenize("mosh --ssh='ssh -p 2222' user@host")
        #expect(tokens == ["mosh", "--ssh=ssh -p 2222", "user@host"])
    }

    @Test func handlesBackslashEscape() throws {
        let tokens = try tokenizer.tokenize(#"ssh \"foo\" host"#)
        #expect(tokens == ["ssh", "\"foo\"", "host"])
    }

    @Test func stripsEnvPrefix() throws {
        let tokens = try tokenizer.tokenize("DEBUG=1 SSH_AUTH_SOCK=/tmp/sock ssh host")
        #expect(tokens == ["ssh", "host"])
    }

    @Test func refusesCommandSubstitution() {
        #expect(throws: ShellTokenizer.TokenError.self) {
            _ = try tokenizer.tokenize("ssh $(whoami)@host")
        }
        #expect(throws: ShellTokenizer.TokenError.self) {
            _ = try tokenizer.tokenize("ssh `hostname`")
        }
    }

    @Test func throwsOnUnterminatedQuote() {
        #expect(throws: ShellTokenizer.TokenError.self) {
            _ = try tokenizer.tokenize(#"ssh "host"#)
        }
    }
}

@Suite("HostTokenParser")
struct HostTokenParserTests {
    @Test func plainHost() {
        let result = HostTokenParser.parse("example.com")
        #expect(result?.user == nil)
        #expect(result?.host == "example.com")
        #expect(result?.port == nil)
    }

    @Test func userAtHost() {
        let result = HostTokenParser.parse("dan@example.com")
        #expect(result?.user == "dan")
        #expect(result?.host == "example.com")
    }

    @Test func hostWithPort() {
        let result = HostTokenParser.parse("example.com:2222")
        #expect(result?.host == "example.com")
        #expect(result?.port == 2222)
    }

    @Test func userAtHostWithPort() {
        let result = HostTokenParser.parse("dan@example.com:2222")
        #expect(result?.user == "dan")
        #expect(result?.host == "example.com")
        #expect(result?.port == 2222)
    }

    @Test func ipv6Bracketed() {
        let result = HostTokenParser.parse("[::1]:22")
        #expect(result?.host == "::1")
        #expect(result?.port == 22)
    }
}

@Suite("CommandExtractors")
struct CommandExtractorsTests {
    let chain = CommandExtractorChain()

    @Test func sshSimpleUserAtHost() {
        let results = chain.extract(line: "ssh dan@example.com", source: .zshHistory(lineNumber: 1))
        #expect(results.count == 1)
        #expect(results[0].user == "dan")
        #expect(results[0].hostname == "example.com")
        #expect(results[0].port == 22)
    }

    @Test func sshPortFlag() {
        let r = chain.extract(line: "ssh -p 2222 user@host", source: .bashHistory(lineNumber: 5))
        #expect(r[0].port == 2222)
        #expect(r[0].user == "user")
    }

    @Test func sshIdentityFlag() {
        let r = chain.extract(line: "ssh -i ~/.ssh/foo user@host", source: .bashHistory(lineNumber: 5))
        #expect(r[0].identityFile == "~/.ssh/foo")
    }

    @Test func sshJumpFlag() {
        let r = chain.extract(line: "ssh -J jump@bastion target.example.com", source: .bashHistory(lineNumber: 5))
        #expect(r[0].proxyJump == "jump@bastion")
        #expect(r[0].hostname == "target.example.com")
    }

    @Test func sshDashO() {
        let r = chain.extract(line: "ssh -o Port=2222 -o User=dan host.example.com", source: .zshHistory(lineNumber: 1))
        #expect(r[0].port == 2222)
        #expect(r[0].user == "dan")
        #expect(r[0].hostname == "host.example.com")
    }

    @Test func sshURI() {
        let r = chain.extract(line: "ssh ssh://dan@host:2222/", source: .zshHistory(lineNumber: 1))
        #expect(r[0].user == "dan")
        #expect(r[0].hostname == "host")
        #expect(r[0].port == 2222)
    }

    @Test func sshTrailingCommandIgnored() {
        let r = chain.extract(line: "ssh dan@host ls -la /tmp", source: .zshHistory(lineNumber: 1))
        #expect(r[0].hostname == "host")
    }

    @Test func scpCapitalP() {
        let r = chain.extract(line: "scp -P 22 file user@host:path", source: .zshHistory(lineNumber: 1))
        #expect(r[0].port == 22)
        #expect(r[0].user == "user")
        #expect(r[0].hostname == "host")
    }

    @Test func rsyncEFlag() {
        let r = chain.extract(line: #"rsync -e "ssh -p 2222" src host:dst"#, source: .bashHistory(lineNumber: 1))
        #expect(r.first?.port == 2222)
        #expect(r.first?.hostname == "host")
    }

    @Test func moshNestedSshPort() {
        let r = chain.extract(line: #"mosh --ssh="ssh -p 2222" user@host"#, source: .zshHistory(lineNumber: 1))
        #expect(r.first?.port == 2222)
        #expect(r.first?.user == "user")
    }

    @Test func gitScpStyleURL() {
        let r = chain.extract(line: "git clone git@github.com:owner/repo.git", source: .zshHistory(lineNumber: 1))
        #expect(r.first?.user == "git")
        #expect(r.first?.hostname == "github.com")
    }

    @Test func gitSSHURL() {
        let r = chain.extract(line: "git clone ssh://git@github.com:22/owner/repo.git", source: .zshHistory(lineNumber: 1))
        #expect(r.first?.user == "git")
        #expect(r.first?.hostname == "github.com")
        #expect(r.first?.port == 22)
    }

    @Test func localhostFiltered() {
        let r = chain.extract(line: "ssh localhost", source: .zshHistory(lineNumber: 1))
        #expect(r.isEmpty)
    }
}

@Suite("HistoryParsers")
struct HistoryParsersTests {

    @Test func bashPlainAndTimestamped() {
        let parser = BashHistoryParser()
        let text = """
        ssh foo
        #1700000000
        ssh -p 22 bar
        """
        let lines = parser.extractLines(from: text)
        #expect(lines.count == 2)
        #expect(lines[0].line == "ssh foo")
        #expect(lines[0].timestamp == nil)
        #expect(lines[1].line == "ssh -p 22 bar")
        #expect(lines[1].timestamp != nil)
    }

    @Test func zshExtendedAndPlain() {
        let parser = ZshHistoryParser()
        let text = """
        : 1700000000:0;ssh foo
        ssh bar
        : 1700000060:42;ssh -p 22 baz
        """
        let lines = parser.extractLines(from: text)
        #expect(lines.count == 3)
        #expect(lines[0].line == "ssh foo")
        #expect(lines[0].timestamp == Date(timeIntervalSince1970: 1700000000))
        #expect(lines[1].line == "ssh bar")
        #expect(lines[1].timestamp == nil)
        #expect(lines[2].line == "ssh -p 22 baz")
    }

    @Test func fishYAMLFormat() {
        let parser = FishHistoryParser()
        let text = """
        - cmd: ssh dan@first
          when: 1700000000
        - cmd: ssh dan@second
          when: 1700000060
        """
        let lines = parser.extractLines(from: text)
        #expect(lines.count == 2)
        #expect(lines[0].line == "ssh dan@first")
        #expect(lines[0].timestamp == Date(timeIntervalSince1970: 1700000000))
    }

    @Test func knownHostsSkipsHashed() {
        let parser = KnownHostsParser()
        let text = """
        example.com ssh-ed25519 AAAA...
        |1|hashedstuff= ssh-ed25519 AAAA...
        @cert-authority *.example.com ssh-ed25519 AAAA...
        [other.example.com]:2222 ssh-ed25519 AAAA...
        """
        let results = parser.extract(from: text)
        let hosts = Set(results.map { $0.hostname })
        #expect(hosts.contains("example.com"))
        #expect(hosts.contains("other.example.com"))
        #expect(!hosts.contains { $0.contains("hashedstuff") })
    }
}

@Suite("ImportEngine alias suggestion")
struct ImportAliasSuggestionTests {
    @Test func dnsHostnameUsesFirstLabel() {
        let parsed = ParsedConnection(hostname: "prod-db.example.com", source: .zshHistory(lineNumber: 1))
        #expect(ImportEngine.suggestAlias(for: parsed) == "prod-db")
    }

    @Test func ipv4UsesDashes() {
        let parsed = ParsedConnection(hostname: "10.0.5.21", source: .zshHistory(lineNumber: 1))
        #expect(ImportEngine.suggestAlias(for: parsed) == "10-0-5-21")
    }

    @Test func bareHostnameUsedAsIs() {
        let parsed = ParsedConnection(hostname: "prod", source: .zshHistory(lineNumber: 1))
        #expect(ImportEngine.suggestAlias(for: parsed) == "prod")
    }
}

@Suite("ImportCandidate dedup")
struct ImportDedupTests {
    @Test func dedupKeyMatchesOnHostPortUser() {
        let a = ParsedConnection(user: "dan", hostname: "Example.com", port: 22, source: .zshHistory(lineNumber: 1))
        let b = ParsedConnection(user: "dan", hostname: "example.com", port: 22, source: .bashHistory(lineNumber: 2))
        #expect(ParsedConnection.DedupKey(a) == ParsedConnection.DedupKey(b))
    }

    @Test func differentUsersDoNotDedup() {
        let a = ParsedConnection(user: "dan", hostname: "host", source: .zshHistory(lineNumber: 1))
        let b = ParsedConnection(user: "root", hostname: "host", source: .zshHistory(lineNumber: 2))
        #expect(ParsedConnection.DedupKey(a) != ParsedConnection.DedupKey(b))
    }

    @Test func differentPortsDoNotDedup() {
        let a = ParsedConnection(hostname: "host", port: 22, source: .zshHistory(lineNumber: 1))
        let b = ParsedConnection(hostname: "host", port: 2222, source: .zshHistory(lineNumber: 2))
        #expect(ParsedConnection.DedupKey(a) != ParsedConnection.DedupKey(b))
    }
}
