import Foundation
import CryptoKit

// Public-key-only verification: proves that the shipped trust root matches the signature.
do {
    guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
    let keyText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rawKey = Data(base64Encoded: keyText), rawKey.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else { throw CocoaError(.fileReadCorruptFile) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else { throw CocoaError(.fileReadCorruptFile) }
    var forged = signature; forged[0] ^= 1
    guard !key.isValidSignature(forged, for: archive) else { throw CocoaError(.fileReadCorruptFile) }
    print("PASS: shipped public key validates the DMG; a modified signature is rejected.")
} catch {
    fputs("Update signature validation failed. No update should be published.\n", stderr)
    exit(1)
}
