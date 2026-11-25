import CryptoKit
import Foundation

/// Reads and writes `.reachly` files: either the plain `ReachlyDocument` JSON or an
/// envelope holding it encrypted with Argon2id → ChaCha20-Poly1305.
public enum ReachlyFile {
    public static let fileExtension = "reachly"
    public static let uniformTypeIdentifier = "io.github.edwardrem.reachly.export"

    public enum Error: LocalizedError, Equatable {
        case notAReachlyFile
        case unsupportedSchema(Int)
        case passphraseRequired
        case wrongPassphrase
        case corrupt(String)
        case plainExportCannotIncludeSecrets

        public var errorDescription: String? {
            switch self {
            case .notAReachlyFile: "This is not a Reachly export file."
            case .unsupportedSchema(let version): "This file was written by a newer Reachly (schema \(version)). Update the app to import it."
            case .passphraseRequired: "This file is encrypted. Enter its passphrase."
            case .wrongPassphrase: "The passphrase is wrong, or the file has been altered."
            case .corrupt(let detail): "The file could not be read: \(detail)."
            case .plainExportCannotIncludeSecrets: "Passwords and private keys can only be exported into an encrypted file."
            }
        }
    }

    /// The encrypted container.
    public struct Envelope: Codable, Sendable, Equatable {
        public struct KDF: Codable, Sendable, Equatable {
            public var name: String
            public var salt: String
            public var memoryKiB: UInt32
            public var iterations: UInt32
            public var parallelism: UInt32
        }

        public var format: String = "reachly"
        public var version: Int = 1
        public var kdf: KDF
        public var cipher: String = "chacha20-poly1305"
        public var nonce: String
        public var ciphertext: String
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Serialises `document`; with a passphrase, encrypts it. Secrets are
    /// refused without a passphrase.
    public static func encode(_ document: ReachlyDocument, passphrase: String?, kdf: Argon2.Parameters = .exportDefault) throws -> Data {
        var document = document
        document.format = "reachly"
        document.schemaVersion = ReachlyDocument.currentSchemaVersion
        if document.secrets?.isEmpty == true { document.secrets = nil }
        guard let passphrase, !passphrase.isEmpty else {
            guard document.secrets == nil else { throw Error.plainExportCannotIncludeSecrets }
            return try encoder().encode(document)
        }
        let plaintext = try encoder().encode(document)
        var salt = [UInt8](repeating: 0, count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let keyBytes = try Argon2.hash(password: Array(passphrase.utf8), salt: salt, parameters: kdf, outputLength: 32)
        let key = SymmetricKey(data: keyBytes)
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        let envelope = Envelope(
            kdf: Envelope.KDF(
                name: kdfName(kdf.variant), salt: Data(salt).base64EncodedString(),
                memoryKiB: kdf.memoryKiB, iterations: kdf.iterations, parallelism: kdf.parallelism),
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString())
        return try encoder().encode(envelope)
    }

    /// True when `data` is an encrypted envelope (so a passphrase is needed).
    public static func isEncrypted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["ciphertext"] != nil
    }

    /// True when `data` looks like a `.reachly` file at all.
    public static func isReachly(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["format"] as? String == "reachly"
    }

    public static func decode(_ data: Data, passphrase: String?) throws -> ReachlyDocument {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? String == "reachly" else {
            throw Error.notAReachlyFile
        }
        var payload = data
        if object["ciphertext"] != nil {
            guard let passphrase, !passphrase.isEmpty else { throw Error.passphraseRequired }
            let envelope: Envelope
            do {
                envelope = try decoder().decode(Envelope.self, from: data)
            } catch {
                throw Error.corrupt("malformed envelope")
            }
            guard envelope.cipher == "chacha20-poly1305", let variant = kdfVariant(envelope.kdf.name) else {
                throw Error.corrupt("unknown cipher or key derivation \(envelope.kdf.name)")
            }
            guard let salt = Data(base64Encoded: envelope.kdf.salt), let nonceData = Data(base64Encoded: envelope.nonce),
                  let sealedData = Data(base64Encoded: envelope.ciphertext), sealedData.count >= 16 else {
                throw Error.corrupt("malformed envelope fields")
            }
            let parameters = Argon2.Parameters(variant: variant, memoryKiB: envelope.kdf.memoryKiB, iterations: envelope.kdf.iterations, parallelism: envelope.kdf.parallelism)
            let keyBytes: [UInt8]
            do {
                keyBytes = try Argon2.hash(password: Array(passphrase.utf8), salt: Array(salt), parameters: parameters, outputLength: 32)
            } catch {
                throw Error.corrupt("key derivation parameters out of range")
            }
            do {
                let nonce = try ChaChaPoly.Nonce(data: nonceData)
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealedData.dropLast(16), tag: sealedData.suffix(16))
                payload = try ChaChaPoly.open(box, using: SymmetricKey(data: keyBytes))
            } catch {
                throw Error.wrongPassphrase
            }
        }
        guard let payloadObject = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Error.corrupt("payload is not JSON")
        }
        let schema = payloadObject["schemaVersion"] as? Int ?? 0
        guard schema >= 1 else { throw Error.corrupt("missing schema version") }
        guard schema <= ReachlyDocument.currentSchemaVersion else { throw Error.unsupportedSchema(schema) }
        do {
            return try decoder().decode(ReachlyDocument.self, from: payload)
        } catch {
            throw Error.corrupt(String(describing: error))
        }
    }

    private static func kdfName(_ variant: Argon2.Variant) -> String {
        switch variant {
        case .d: "argon2d"
        case .i: "argon2i"
        case .id: "argon2id"
        }
    }

    private static func kdfVariant(_ name: String) -> Argon2.Variant? {
        switch name.lowercased() {
        case "argon2d": .d
        case "argon2i": .i
        case "argon2id": .id
        default: nil
        }
    }
}
