import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/networking/infrastructure/tls/transport_security_native.dart';

/// Maps provisioned trust material onto the transport that enforces it.
///
/// This lives in the composition layer because it is the one place allowed to
/// join the bootstrap domain to the networking infrastructure; neither feature
/// may reach into the other.
TransportSecurity provisionedTransportSecurity(
  PlatformTrustMaterial material,
) => switch (material) {
  AndroidTrustMaterial(:final certificateAuthority) =>
    TransportSecurity.provisioned(certificateAuthority),
  // A browser owns its trust store and cannot be given an authority from
  // page script; the operator installs it at the system level instead.
  WebTrustMaterial() => const TransportSecurity.platformDefault(),
};
