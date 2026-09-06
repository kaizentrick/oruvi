import Foundation
import CryptoKit
import Darwin

// Maintainer tool. Creates a NEW Ed25519 signing seed, never reads login credentials.
// Seed format matches Sparkle 2.9's documented 32-byte base64 key-file format.
// The private seed never appears in stdout, a public artifact or a Git commit.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let folder = root.appendingPathComponent(".private", isDirectory: true)
let secret = folder.appendingPathComponent("sparkle.key")
let publicFile = root.appendingPathComponent("Resources/UpdatePublicKey.pub")
do {
    umask(0o077)
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.path) {
        let attributes = try fm.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
    } else { try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    let key: Curve25519.Signing.PrivateKey
    if fm.fileExists(atPath: secret.path) {
        let attributes = try fm.attributesOfItem(atPath: secret.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
        let encoded = try String(contentsOf: secret, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: encoded), raw.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    } else {
        // Refuse to replace a released public key if its matching private key was lost.
        guard !fm.fileExists(atPath: publicFile.path) else { throw CocoaError(.fileReadNoSuchFile) }
        key = Curve25519.Signing.PrivateKey()
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: secret, options: .withoutOverwriting)
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
    let publicText = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
    if fm.fileExists(atPath: publicFile.path) {
        guard try String(contentsOf: publicFile, encoding: .utf8) == publicText else { throw CocoaError(.fileReadCorruptFile) }
    } else {
        try Data(publicText.utf8).write(to: publicFile, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicFile.path)
    }
    print("Update key ready. Back up .private/sparkle.key securely; never commit it.")
} catch {
    fputs("Update key setup failed. Existing keys were not replaced. Restore the original private key if a public key already exists.\n", stderr)
    exit(1)
}
