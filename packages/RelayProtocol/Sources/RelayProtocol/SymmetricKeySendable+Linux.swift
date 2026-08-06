import Crypto

// swift-crypto does not yet declare SymmetricKey Sendable on Linux. The value
// is immutable, while the Apple CryptoKit implementation already conforms.
#if !canImport(Darwin)
extension SymmetricKey: @retroactive @unchecked Sendable {}
#endif
