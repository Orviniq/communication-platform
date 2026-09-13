/// Version-1 metadata for the shared native cryptographic core.
///
/// This contract contains only public capability information. Secret material and
/// primitive inputs are deliberately absent from the piece-07 Flutter boundary.
abstract final class CryptoCoreProtocolV1 {
  static const int abiVersion = 1;
  static const int capabilitiesStructSizeBytes = 32;

  static const Set<CryptoCoreCapability> requiredCapabilities = {
    CryptoCoreCapability.deterministicCbor,
    CryptoCoreCapability.ed25519,
    CryptoCoreCapability.x25519,
    CryptoCoreCapability.mlKem768,
    CryptoCoreCapability.argon2id,
    CryptoCoreCapability.xChaCha20Poly1305,
    CryptoCoreCapability.sha2,
    CryptoCoreCapability.hkdf,
    CryptoCoreCapability.secretStream,
    CryptoCoreCapability.secureRandom,
    CryptoCoreCapability.zeroizingSecrets,
    CryptoCoreCapability.panicContainment,
  };

  static const Set<CryptoCoreCapability> requiredPairwiseCapabilities = {
    CryptoCoreCapability.hybridPqxdhV1,
    CryptoCoreCapability.doubleRatchetV1,
  };

  static const Set<CryptoCoreCapability> requiredApplicationCapabilities = {
    CryptoCoreCapability.deterministicCbor,
    CryptoCoreCapability.applicationMessagesV1,
  };

  static const int knownFeatureBits = (1 << 15) - 1;
}

enum CryptoCoreCapability {
  deterministicCbor(1 << 0),
  ed25519(1 << 1),
  x25519(1 << 2),
  mlKem768(1 << 3),
  argon2id(1 << 4),
  xChaCha20Poly1305(1 << 5),
  sha2(1 << 6),
  hkdf(1 << 7),
  secretStream(1 << 8),
  secureRandom(1 << 9),
  zeroizingSecrets(1 << 10),
  panicContainment(1 << 11),
  hybridPqxdhV1(1 << 12),
  doubleRatchetV1(1 << 13),
  applicationMessagesV1(1 << 14);

  const CryptoCoreCapability(this.featureBit);

  final int featureBit;
}

/// Non-secret capability metadata returned by the versioned native ABI.
final class CryptoCoreCapabilities {
  CryptoCoreCapabilities({
    required this.abiVersion,
    required this.featureBits,
    required this.maxInputBytes,
    required this.maxCborDepth,
    required this.maxCborItems,
  }) : capabilities = Set<CryptoCoreCapability>.unmodifiable(
         CryptoCoreCapability.values.where(
           (capability) => featureBits & capability.featureBit != 0,
         ),
       );

  final int abiVersion;
  final int featureBits;
  final int maxInputBytes;
  final int maxCborDepth;
  final int maxCborItems;
  final Set<CryptoCoreCapability> capabilities;

  bool get supportsRequiredFoundation =>
      capabilities.containsAll(CryptoCoreProtocolV1.requiredCapabilities);

  bool get supportsPairwiseTransportV1 => capabilities.containsAll(
    CryptoCoreProtocolV1.requiredPairwiseCapabilities,
  );

  bool get supportsApplicationMessagesV1 => capabilities.containsAll(
    CryptoCoreProtocolV1.requiredApplicationCapabilities,
  );

  int get unknownFeatureBits =>
      featureBits & ~CryptoCoreProtocolV1.knownFeatureBits;

  @override
  String toString() =>
      'CryptoCoreCapabilities('
      'abiVersion: $abiVersion, '
      'featureBits: 0x${featureBits.toRadixString(16)}, '
      'maxInputBytes: $maxInputBytes, '
      'maxCborDepth: $maxCborDepth, '
      'maxCborItems: $maxCborItems'
      ')';
}
