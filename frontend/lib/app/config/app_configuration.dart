import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/features/bootstrap/application/ports/bootstrap_ports.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';

/// Compile-time public provisioning inputs.
///
/// Concrete origins, CA fingerprints, and SPKI pins are supplied by the controlled
/// build environment. They are deliberately absent from source control.
final class AppProvisioningValues {
  const AppProvisioningValues({
    required this.serverOrigin,
    required this.privateCaSha256,
    required this.primarySpkiSha256,
    required this.backupSpkiSha256,
    this.privateCaPemBase64 = '',
  });

  final String serverOrigin;
  final String privateCaSha256;
  final String primarySpkiSha256;
  final String backupSpkiSha256;

  /// The private authority itself, PEM encoded then base64 encoded so it
  /// survives a single-line compile-time define.
  ///
  /// The fingerprint above only identifies the authority. `dart:io` verifies
  /// against a certificate, not a digest, and it does not read Android's
  /// network security configuration, so the certificate has to be provisioned
  /// here for the app's own transport to trust it.
  final String privateCaPemBase64;
}

/// Locked runtime policy shared by both flavors and asserted independently in tests.
final class AppRuntimePolicy {
  const AppRuntimePolicy._();

  static const lockedDown = AppRuntimePolicy._();

  bool get allowsArbitraryServerSelection => false;
  bool get allowsCertificateBypass => false;
  bool get allowsPublicConnectivityProbes => false;
  bool get allowsRemoteConfiguration => false;
  bool get allowsTelemetry => false;
  bool get allowsThirdPartyRuntimeResources => false;
}

final class CompileTimeBootstrapConfiguration
    implements BootstrapConfigurationPort {
  const CompileTimeBootstrapConfiguration({
    required this.environment,
    required this.platform,
    this.provisioningValues,
  });

  final AppEnvironment environment;
  final BootstrapPlatform platform;
  final AppProvisioningValues? provisioningValues;

  static const _developmentValues = AppProvisioningValues(
    serverOrigin: String.fromEnvironment('DEVELOPMENT_SERVER_ORIGIN'),
    privateCaSha256: String.fromEnvironment('DEVELOPMENT_PRIVATE_CA_SHA256'),
    primarySpkiSha256: String.fromEnvironment(
      'DEVELOPMENT_PRIMARY_SPKI_SHA256',
    ),
    backupSpkiSha256: String.fromEnvironment('DEVELOPMENT_BACKUP_SPKI_SHA256'),
    privateCaPemBase64: String.fromEnvironment(
      'DEVELOPMENT_PRIVATE_CA_PEM_BASE64',
    ),
  );

  static const _productionValues = AppProvisioningValues(
    serverOrigin: String.fromEnvironment('PRODUCTION_SERVER_ORIGIN'),
    privateCaSha256: String.fromEnvironment('PRODUCTION_PRIVATE_CA_SHA256'),
    primarySpkiSha256: String.fromEnvironment('PRODUCTION_PRIMARY_SPKI_SHA256'),
    backupSpkiSha256: String.fromEnvironment('PRODUCTION_BACKUP_SPKI_SHA256'),
    privateCaPemBase64: String.fromEnvironment(
      'PRODUCTION_PRIVATE_CA_PEM_BASE64',
    ),
  );

  AppProvisioningValues get _selectedValues =>
      provisioningValues ??
      switch (environment) {
        AppEnvironment.development => _developmentValues,
        AppEnvironment.production => _productionValues,
      };

  @override
  Future<ConfigurationLoadResult> load() async {
    final values = _selectedValues;
    if (values.serverOrigin.isEmpty || values.privateCaSha256.isEmpty) {
      return const ConfigurationNotProvisioned(
        ConfigurationFailureKind.missingProvisioning,
      );
    }

    final origin = ServerOrigin.parse(values.serverOrigin);
    if (origin == null) {
      return const ConfigurationNotProvisioned(
        ConfigurationFailureKind.invalidOrigin,
      );
    }
    if (!_isSha256Hex(values.privateCaSha256)) {
      return const ConfigurationNotProvisioned(
        ConfigurationFailureKind.invalidPrivateCaFingerprint,
      );
    }

    final PlatformTrustMaterial trustMaterial;
    switch (platform) {
      case BootstrapPlatform.android:
        if (!_isSha256Pin(values.primarySpkiSha256)) {
          return const ConfigurationNotProvisioned(
            ConfigurationFailureKind.invalidPrimaryPin,
          );
        }
        if (!_isSha256Pin(values.backupSpkiSha256)) {
          return const ConfigurationNotProvisioned(
            ConfigurationFailureKind.invalidBackupPin,
          );
        }
        if (values.primarySpkiSha256 == values.backupSpkiSha256) {
          return const ConfigurationNotProvisioned(
            ConfigurationFailureKind.duplicatePins,
          );
        }
        final certificateAuthority = _decodeCertificateAuthority(
          values.privateCaPemBase64,
        );
        if (certificateAuthority == null) {
          // Fail closed rather than fall back to the public root store: a build
          // without the authority cannot verify the provisioned server, and
          // silently trusting public authorities instead would be a downgrade.
          return const ConfigurationNotProvisioned(
            ConfigurationFailureKind.invalidPrivateCaCertificate,
          );
        }
        trustMaterial = AndroidTrustMaterial(
          privateCaSha256: values.privateCaSha256.toLowerCase(),
          primarySpkiSha256: values.primarySpkiSha256,
          backupSpkiSha256: values.backupSpkiSha256,
          certificateAuthority: certificateAuthority,
        );
      case BootstrapPlatform.web:
        trustMaterial = WebTrustMaterial(
          privateCaSha256: values.privateCaSha256.toLowerCase(),
        );
    }

    return ConfigurationLoaded(
      ProvisionedBootstrapConfiguration(
        serverOrigin: origin,
        trustMaterial: trustMaterial,
      ),
    );
  }

  /// Decodes the provisioned authority, or null when it is absent or is not a
  /// PEM certificate.
  ///
  /// This only establishes that the bytes are a certificate container. Whether
  /// the certificate is well formed, unexpired, and usable as an anchor is
  /// decided by the platform TLS implementation when the context is built.
  static Uint8List? _decodeCertificateAuthority(String base64Pem) {
    if (base64Pem.isEmpty) {
      return null;
    }
    final Uint8List decoded;
    try {
      decoded = base64.decode(base64Pem.trim());
    } on FormatException {
      return null;
    }
    if (decoded.isEmpty) {
      return null;
    }
    return ascii
            .decode(decoded, allowInvalid: true)
            .contains('-----BEGIN CERTIFICATE-----')
        ? decoded
        : null;
  }

  static bool _isSha256Hex(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static bool _isSha256Pin(String value) =>
      RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(value);
}
