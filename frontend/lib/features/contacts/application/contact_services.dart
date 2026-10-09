import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_search.dart';

final class DirectoryService {
  const DirectoryService({required this.remote, required this.local});

  static const maximumPageSize = 50;

  final DirectoryRemotePort remote;
  final ContactLocalPort local;

  Future<Result<void>> refresh() async {
    final fetched = await remote.fetchActivatedUsers();
    return fetched.fold(
      onSuccess: local.replaceDirectory,
      onFailure: Result.failure,
    );
  }

  Stream<DirectoryPage> watch({
    required String ownUserId,
    required String query,
    required int pageSize,
  }) {
    final bounded = pageSize.clamp(1, maximumPageSize);
    final normalized = query.trim().toLowerCase();
    return local.watchContacts(ownUserId: ownUserId).map((contacts) {
      final matching = normalized.isEmpty
          ? contacts
          : contacts
                .where((contact) => contactMatchesSearch(contact, normalized))
                .toList(growable: false);
      return DirectoryPage(
        contacts: matching.take(bounded).toList(growable: false),
        offset: 0,
        hasMore: matching.length > bounded,
        offline: false,
      );
    });
  }

  DirectoryPage page({
    required List<ContactProjection> contacts,
    required int offset,
    required int pageSize,
    required bool offline,
  }) {
    final bounded = pageSize.clamp(1, maximumPageSize);
    final start = offset.clamp(0, contacts.length);
    final end = (start + bounded).clamp(start, contacts.length);
    return DirectoryPage(
      contacts: contacts.sublist(0, end),
      offset: end,
      hasMore: end < contacts.length,
      offline: offline,
    );
  }
}

final class ProfileService {
  const ProfileService({
    required this.remote,
    required this.local,
    required this.authentication,
    required this.protection,
    required this.keyDistribution,
  });

  final ProfileRemotePort remote;
  final ContactLocalPort local;
  final PeerAuthenticationService authentication;
  final ProfileProtectionPort protection;
  final ProfileKeyDistributionPort keyDistribution;

  Future<Result<AuthenticatedProfile?>> refreshPeer(String userId) async {
    final authenticated = await authentication.refreshPeer(
      userId: userId,
      requirePrekeys: false,
    );
    if (authenticated case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final peer = (authenticated as Success<AuthenticatedPeer>).value;
    if (!peer.trust.isSensitiveActionAllowed) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.policyBlocked),
      );
    }
    final fetched = await remote.fetchProfile(userId: userId);
    if (fetched case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final ciphertext = (fetched as Success<ProfileCiphertext?>).value;
    if (ciphertext == null) {
      return const Result.success(null);
    }
    final keyResult = await keyDistribution.receive(
      ownerUserId: userId,
      profileVersion: ciphertext.version,
    );
    if (keyResult case FailureResult(failure: final failure)) {
      await local.writeProfile(userId, ciphertext, null);
      return Result.failure(failure);
    }
    final key = (keyResult as Success<ProfileKeyMaterial?>).value;
    if (key == null) {
      await local.writeProfile(userId, ciphertext, null);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final opened = await protection.open(ciphertext: ciphertext, key: key);
    if (opened case FailureResult(failure: final failure)) {
      await local.writeProfile(userId, ciphertext, null);
      return Result.failure(failure);
    }
    final profile = (opened as Success<OpenedProfile>).value;
    final liveSigner = peer.devices.any(
      (device) => device.deviceId == profile.authorDeviceId,
    );
    if (profile.authorUserId != userId ||
        profile.revision != ciphertext.version ||
        !liveSigner) {
      await local.writeProfile(userId, ciphertext, null);
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.unauthenticatedInput),
      );
    }
    final authenticatedProfile = AuthenticatedProfile(
      displayName: profile.draft.displayName,
      avatarSeed: profile.draft.avatarSeed,
      version: profile.revision,
      authorDeviceId: profile.authorDeviceId,
    );
    final stored = await local.writeProfile(
      userId,
      ciphertext,
      authenticatedProfile,
    );
    return stored.fold(
      onSuccess: (_) => Result.success(authenticatedProfile),
      onFailure: Result.failure,
    );
  }

  Future<Result<AuthenticatedProfile>> publishOwn(ProfileDraft draft) async {
    if (!draft.isValid) {
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final accountResult = await local.readLocalIdentity();
    if (accountResult case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    final account = (accountResult as Success<LocalAccountIdentity>).value;
    var current = await remote.fetchOwnProfile();
    if (current case FailureResult(
      failure: BackendFailure(code: BackendFailureCode.notFound),
    )) {
      current = const Result.success(null);
    }
    if (current case FailureResult(failure: final failure)) {
      return Result.failure(failure);
    }
    var revision =
        ((current as Success<ProfileCiphertext?>).value?.version ?? 0) + 1;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final sealed = await protection.seal(
        profile: draft,
        authorUserId: account.userId,
        authorDeviceId: account.deviceId,
        revision: revision,
      );
      if (sealed case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final (ciphertext, key) =
          (sealed as Success<(ProfileCiphertext, ProfileKeyMaterial)>).value;
      final published = await remote.publishOwnProfile(ciphertext);
      if (published case FailureResult(
        failure: BackendFailure(code: BackendFailureCode.staleVersion),
      )) {
        final latest = await remote.fetchOwnProfile();
        if (latest case Success<ProfileCiphertext?>(:final value)) {
          revision = (value?.version ?? revision) + 1;
          continue;
        }
      }
      if (published case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final distributed = await keyDistribution.publish(
        ownerUserId: account.userId,
        profileVersion: revision,
        key: key,
      );
      if (distributed case FailureResult(failure: final failure)) {
        return Result.failure(failure);
      }
      final profile = AuthenticatedProfile(
        displayName: draft.displayName.trim(),
        avatarSeed: draft.avatarSeed,
        version: revision,
        authorDeviceId: account.deviceId,
      );
      final stored = await local.writeProfile(
        account.userId,
        ciphertext,
        profile,
      );
      return stored.fold(
        onSuccess: (_) => Result.success(profile),
        onFailure: Result.failure,
      );
    }
    return const Result.failure(
      BackendFailure(BackendFailureCode.staleVersion),
    );
  }
}
