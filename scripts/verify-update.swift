import Foundation
import CryptoKit

// Public-key-only verification: neither the signing key nor Keychain access is needed.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update.swift archive public-key signature\n", stderr)
    exit(2)
}
do {
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard verifier.isValidSignature(signature, for: data) else {
        fputs("Invalid update signature\n", stderr); exit(1)
    }
    print("Update signature verified")
} catch { fputs("Update verification failed: \(error)\n", stderr); exit(1) }
