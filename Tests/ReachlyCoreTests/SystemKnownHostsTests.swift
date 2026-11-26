import Foundation
import SwiftData
import Testing
@testable import ReachlyCore

@Suite struct SystemKnownHostsTests {
    // Throwaway public keys made with ssh-keygen for these tests.
    static let ed1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHm6Dr3o1wsVsTgcfnya+qapB0AyrKw9AQ/BzhuHBmue"
    static let ed1Fingerprint = "SHA256:KEC/xO9PLTs+2zf8LOXMiaQZ9u96yQTndRB1u11pIZw"
    static let ed2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILgyNImXQPk89j1+304GGAk6saOy9Aqyt3I+SyYAgYqb"
    static let ec1 = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBE2SrBLAJVFtWkCAipJKOWZXzuaFrga3Kn4wmzC2bBG+NQAiQnJ+4dDW34wtKuTuUebTbLxy0Ua+kyFPMpygq/w="
    static let ec1Fingerprint = "SHA256:BybNU3CgIzHxg/VcB7xMm0Z4MOxRqVhemhc9wB32maU"
    static let ec2 = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCdjRYckg1V92ECWyZZjVgFKre3wl5c+lj175jXM/sfFvFJZZ2NvXeXn5MgQ4W8JmVwXNpdkitE4i743AbwTI3c="

    private func server(_ scan: SystemKnownHosts.Scan, _ id: String) -> SystemKnownHosts.Server? {
        scan.servers.first { $0.id == id }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "reachly-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: - Parsing

    @Test func readsPlainBracketedAndIPv6Names() {
        let text = """
        Example.COM \(Self.ed1)
        [Box.Example.com]:2222 \(Self.ed1)
        [::1]:2200 \(Self.ed1)
        fe80::1 \(Self.ed1)
        [bracketed.example.com] \(Self.ed1)
        [zero.example.com]:0 \(Self.ed1)
        [word.example.com]:ssh \(Self.ed1)
        [open.example.com \(Self.ed1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(Set(scan.servers.map(\.id)) == ["example.com", "[box.example.com]:2222", "[::1]:2200", "fe80::1", "bracketed.example.com"])
        let box = server(scan, "[box.example.com]:2222")
        #expect(box?.hostname == "box.example.com")
        #expect(box?.port == 2222)
        #expect(server(scan, "[::1]:2200")?.hostname == "::1")
        #expect(server(scan, "fe80::1")?.port == 22)
    }

    @Test func toleratesCommentsBlankLinesCRLFAndTrailingComments() throws {
        let text = "# a comment\r\n\r\n   \r\n\tweb.example.com \(Self.ed1) user@laptop and more words\r\n  # indented comment\r\n"
        let scan = SystemKnownHosts.parse([text])
        let web = try #require(scan.servers.first)
        #expect(scan.servers.count == 1)
        #expect(web.id == "web.example.com")
        #expect(web.keys == [SystemKnownHosts.Key(keyType: "ssh-ed25519", publicKey: Self.ed1, fingerprintSHA256: Self.ed1Fingerprint)])
        #expect(scan.hashedEntryCount == 0)
    }

    @Test func fingerprintsMatchSSHKeygen() throws {
        let scan = SystemKnownHosts.parse(["a.example.com \(Self.ed1)\na.example.com \(Self.ec1)"])
        let keys = try #require(scan.servers.first?.keys)
        #expect(keys.map(\.fingerprintSHA256) == [Self.ed1Fingerprint, Self.ec1Fingerprint])
        #expect(keys.map(\.keyType) == ["ssh-ed25519", "ecdsa-sha2-nistp256"])
    }

    @Test func skipsInvalidKeys() {
        let ed1Blob = Self.ed1.split(separator: " ")[1]
        let text = """
        bad-base64.example.com ssh-ed25519 not*base64
        wrong-type.example.com ssh-rsa \(ed1Blob)
        missing-key.example.com ssh-ed25519
        empty-type.example.com  \(ed1Blob)
        truncated.example.com ssh-ed25519 AAAAC3NzaC1l
        good.example.com \(Self.ed1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["good.example.com"])
    }

    @Test func skipsWildcardsNegationsAndCertificateAuthorities() {
        let text = """
        *.example.com \(Self.ed1)
        host?.example.com \(Self.ed1)
        !bad.example.com,ok.example.com \(Self.ed1)
        @cert-authority *.corp.example.com \(Self.ec1)
        @cert-authority ca.example.com \(Self.ec1)
        @unknown-marker marker.example.com \(Self.ec1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["ok.example.com"])
        #expect(scan.servers.first?.aliases == [])
    }

    @Test func hashedEntriesAreCountedNotListed() {
        let text = """
        |1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VE8wmZL7suNrYQLITLCg= \(Self.ed1)
        |1|BBBBKeoE/eEWhi10WpGv4OdiO6Y=|CCCCQV0VE8wmZL7suNrYQLITLCg= \(Self.ec1)
        |1|DDDDKeoE/eEWhi10WpGv4OdiO6Y=|EEEEQV0VE8wmZL7suNrYQLITLCg= ssh-ed25519 broken
        @revoked |1|GGGGKeoE/eEWhi10WpGv4OdiO6Y=|HHHHQV0VE8wmZL7suNrYQLITLCg= \(Self.ec2)
        |1|IIIIKeoE/eEWhi10WpGv4OdiO6Y=|JJJJQV0VE8wmZL7suNrYQLITLCg=,plain.example.com \(Self.ed2)
        """
        let scan = SystemKnownHosts.parse([text])
        // The broken key and the revoked marker do not count; the mixed line is listed by its plain name.
        #expect(scan.hashedEntryCount == 2)
        #expect(scan.servers.map(\.id) == ["plain.example.com"])
    }

    @Test func revokedKeysAreNeverCarriedForAnyHost() throws {
        let first = """
        revoked-only.example.com \(Self.ed2)
        mixed.example.com \(Self.ed2)
        mixed.example.com \(Self.ec1)
        """
        // A @revoked line in known_hosts2 applies to keys in known_hosts too.
        let second = "@revoked * \(Self.ed2)\n"
        let scan = SystemKnownHosts.parse([first, second])
        #expect(server(scan, "revoked-only.example.com") == nil)
        let mixed = try #require(server(scan, "mixed.example.com"))
        #expect(mixed.keys.map(\.publicKey) == [Self.ec1])
        #expect(!scan.servers.flatMap(\.keys).contains { $0.publicKey == Self.ed2 })
    }

    @Test func onePerServerWithEveryKeyTypeAndItsAddresses() throws {
        let text = """
        example.com,203.0.113.5 \(Self.ed1)
        example.com \(Self.ec1)
        203.0.113.5 \(Self.ec2)
        198.51.100.9 \(Self.ed2)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["example.com", "198.51.100.9"])
        let example = try #require(scan.servers.first)
        #expect(example.aliases == [SystemKnownHosts.Endpoint(host: "203.0.113.5")])
        // Keys ssh accepts for the name; the key recorded only for the address stays there.
        #expect(example.keys.map(\.publicKey) == [Self.ed1, Self.ec1])
    }

    @Test func firstNonAddressNameIsShownAndOrderIsStable() throws {
        let text = """
        203.0.113.7,build.example.com,build \(Self.ed1)
        web10.example.com \(Self.ed1)
        web2.example.com \(Self.ed1)
        10.0.0.1 \(Self.ed1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["build.example.com", "web2.example.com", "web10.example.com", "10.0.0.1"])
        #expect(scan.servers[0].aliases.map(\.host) == ["203.0.113.7", "build"])
    }

    @Test func namesOnTheSameLineAreOneServerWhicheverLineComesFirst() {
        let text = """
        short \(Self.ec1)
        long.example.com,short \(Self.ed1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["short"])
        #expect(scan.servers.first?.keys.map(\.publicKey) == [Self.ec1, Self.ed1])
    }

    @Test func sharedAddressesDoNotMergeDifferentServers() {
        let text = """
        alpha.example.com,10.0.0.5 \(Self.ed1)
        beta.example.com,10.0.0.5 \(Self.ed2)
        10.0.0.5 \(Self.ec1)
        """
        let scan = SystemKnownHosts.parse([text])
        #expect(scan.servers.map(\.id) == ["alpha.example.com", "beta.example.com"])
        #expect(scan.servers.map { $0.keys.map(\.publicKey) } == [[Self.ed1], [Self.ed2]])
    }

    @Test func aKeyTypeListedWithTwoKeysIsNotCarried() throws {
        let text = """
        lb.example.com \(Self.ed1)
        lb.example.com \(Self.ed2)
        lb.example.com \(Self.ec1)
        lb.example.com \(Self.ec1) duplicate line
        """
        let lb = try #require(SystemKnownHosts.parse([text]).servers.first)
        #expect(lb.keys.map(\.publicKey) == [Self.ec1])
    }

    @Test func capsTheNumberOfServers() {
        let text = (1...5).map { "host\($0).example.com \(Self.ed1)" }.joined(separator: "\n")
        let scan = SystemKnownHosts.parse([text], maximumServers: 3)
        #expect(scan.servers.count == 3)
        #expect(scan.isTruncated)
        #expect(!SystemKnownHosts.parse([text]).isTruncated)
    }

    @Test func usersComeFromConfigBlocksThatNameTheServer() throws {
        let config = SSHConfigFile.parse("""
        Host *
            User everyone
        Host web
            HostName Web.Example.com
            User deploy
        Host web-again
            HostName web.example.com
            User second
        Host alt
            HostName alt.example.com
            Port 2222
            User alt
        Host db.example.com
            User dba
        """)
        let text = "web.example.com \(Self.ed1)\n[alt.example.com]:2222 \(Self.ed1)\nalt.example.com \(Self.ed1)\ndb.example.com \(Self.ed1)\nother.example.com \(Self.ed1)"
        let scan = SystemKnownHosts.parse([text], config: config)
        #expect(server(scan, "web.example.com")?.configUser == "deploy")
        #expect(server(scan, "[alt.example.com]:2222")?.configUser == "alt")
        #expect(server(scan, "alt.example.com")?.configUser == nil)
        #expect(server(scan, "db.example.com")?.configUser == "dba")
        // `Host *` is a pattern; the ~/.ssh/config import does not apply those either.
        #expect(server(scan, "other.example.com")?.configUser == nil)
    }

    // MARK: - Filtering

    @Test func hidesHostsAlreadyInReachlyCodeHostingAndHiddenRows() {
        let text = """
        web.example.com \(Self.ed1)
        [web.example.com]:2222 \(Self.ed1)
        db.example.com,192.0.2.10 \(Self.ed1)
        github.com,140.82.121.4 \(Self.ed1)
        140.82.121.4 \(Self.ec1)
        [ssh.github.com]:443 \(Self.ed1)
        gitlab.com \(Self.ed1)
        bitbucket.org \(Self.ed1)
        codeberg.org \(Self.ed1)
        quiet.example.com \(Self.ed1)
        left.example.com \(Self.ed1)
        """
        let scan = SystemKnownHosts.parse([text])
        let existing = [
            SystemKnownHosts.Endpoint(host: " WEB.example.com ", port: 22),
            SystemKnownHosts.Endpoint(host: "192.0.2.10", port: 22),
        ]
        let suggestions = SystemKnownHosts.suggestions(from: scan, existing: existing, hidden: ["quiet.example.com", "gone.example.com"])
        // web:22 exists (case-insensitive); web:2222 is another server; db exists under its address.
        #expect(suggestions.servers.map(\.id) == ["left.example.com", "[web.example.com]:2222"])
        #expect(suggestions.hiddenCount == 1)

        let everything = SystemKnownHosts.suggestions(from: scan, existing: [], hidden: [], excluding: [])
        #expect(everything.servers.count == 10)
    }

    // MARK: - Adding

    @MainActor
    @Test func carriedKeysAreStoredUnderTheHostAndPortASessionChecks() async throws {
        // TerminalSession.verifyHostKey asks the store about `hop.hostname` and `hop.port`,
        // which HostDescriptor(SSHHost) copies from the saved host unchanged. The keys must
        // therefore be stored under the new SSHHost's own hostname and port, or the first
        // connection still asks the user to trust a key the Mac already trusts.
        let scan = SystemKnownHosts.parse(["[Build.Example.COM]:2222,198.51.100.7 \(Self.ed1) comment\n[build.example.com]:2222 \(Self.ec1)"])
        let server = try #require(scan.servers.first)
        let container = try ModelContainer(for: Schema(ReachlySchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let host = SystemKnownHosts.makeHost(for: server, localUsername: "me")
        container.mainContext.insert(host)
        try container.mainContext.save()
        #expect(host.hostname == "build.example.com")
        #expect(host.port == 2222)

        let store = KnownHostsStore(url: temporaryDirectory().appending(path: "known_hosts.json"))
        let outcome = try await SystemKnownHosts.trust(server.keys, hostname: host.hostname, port: host.port, in: store)
        #expect(outcome == .init(added: 2))
        #expect(await store.verdict(host: host.hostname, port: host.port, keyType: "ssh-ed25519", publicKey: Self.ed1) == .known)
        #expect(await store.verdict(host: host.hostname, port: host.port, keyType: "ecdsa-sha2-nistp256", publicKey: Self.ec1) == .known)
        // Not under the address on the same line, and not on the default port.
        #expect(await store.verdict(host: "198.51.100.7", port: 2222, keyType: "ssh-ed25519", publicKey: Self.ed1) == .unknown)
        #expect(await store.verdict(host: host.hostname, port: 22, keyType: "ssh-ed25519", publicKey: Self.ed1) == .unknown)
        let entries = await store.allEntries()
        #expect(entries.map(\.fingerprintSHA256).sorted() == [Self.ec1Fingerprint, Self.ed1Fingerprint].sorted())
    }

    @Test func trustingKeepsReachlysOwnDecisions() async throws {
        let store = KnownHostsStore(url: temporaryDirectory().appending(path: "known_hosts.json"))
        // Reachly already trusts a different Ed25519 key and the same ECDSA key.
        try await store.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKey: Self.ed2, fingerprintSHA256: "SHA256:reachly")
        try await store.remember(host: "example.com", port: 22, keyType: "ecdsa-sha2-nistp256", publicKey: Self.ec1, fingerprintSHA256: Self.ec1Fingerprint)
        let server = try #require(SystemKnownHosts.parse(["example.com \(Self.ed1)\nexample.com \(Self.ec1)"]).servers.first)

        let outcome = try await SystemKnownHosts.trust(server.keys, hostname: server.hostname, port: server.port, in: store)
        #expect(outcome == .init(alreadyTrusted: 1, leftDifferent: 1))
        // The changed-key prompt still sees Reachly's key, not the one from ~/.ssh.
        #expect(await store.verdict(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKey: Self.ed2) == .known)
        #expect(await store.allEntries().count == 2)
    }

    @MainActor
    @Test func newHostsUseTheImportDefaults() throws {
        let container = try ModelContainer(for: Schema(ReachlySchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let plain = SystemKnownHosts.Server(endpoint: .init(host: "box.example.com"), keys: [])
        let configured = SystemKnownHosts.Server(endpoint: .init(host: "web.example.com", port: 2222), keys: [], configUser: "deploy")
        let a = SystemKnownHosts.makeHost(for: plain, localUsername: "me", sortOrder: 4)
        let b = SystemKnownHosts.makeHost(for: configured, localUsername: "me")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        #expect(a.name == "box.example.com")
        #expect(a.hostname == "box.example.com")
        #expect(a.port == 22)
        #expect(a.username == "me")
        #expect(a.authMethod == .password)
        #expect(a.sortOrder == 4)
        #expect(b.displayTarget == "deploy@web.example.com:2222")
        #expect(SystemKnownHosts.makeHost(for: plain).username == NSUserName())
    }

    // MARK: - Files

    @Test func loadsBothFilesAndTheConfigFromADirectory() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "one.example.com \(Self.ed1)\n".write(to: directory.appending(path: "known_hosts"), atomically: true, encoding: .utf8)
        try "two.example.com \(Self.ed1)\n@revoked * \(Self.ed1)\nthree.example.com \(Self.ec1)\n".write(to: directory.appending(path: "known_hosts2"), atomically: true, encoding: .utf8)
        try "Host three\n  HostName three.example.com\n  User ops\n".write(to: directory.appending(path: "config"), atomically: true, encoding: .utf8)

        let scan = SystemKnownHosts.load(sshDirectory: directory)
        #expect(scan.servers.map(\.id) == ["three.example.com"])
        #expect(scan.servers.first?.configUser == "ops")

        let stamps = SystemKnownHosts.stamps(sshDirectory: directory)
        #expect(stamps.count == 3)
        #expect(stamps.allSatisfy { $0 != nil })
        #expect(SystemKnownHosts.stamps(sshDirectory: directory) == stamps)
    }

    @Test func missingAndOversizedFilesAreIgnored() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SystemKnownHosts.load(sshDirectory: directory) == .empty)
        #expect(SystemKnownHosts.stamps(sshDirectory: directory) == [nil, nil, nil])

        let file = directory.appending(path: "known_hosts")
        try "big.example.com \(Self.ed1)\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SystemKnownHosts.readText(at: file, limit: 1024) != nil)
        #expect(SystemKnownHosts.readText(at: file, limit: 16) == nil)
        #expect(SystemKnownHosts.readText(at: directory) == nil)
        #expect(SystemKnownHosts.maximumFileSize == 8 * 1024 * 1024)
    }
}
