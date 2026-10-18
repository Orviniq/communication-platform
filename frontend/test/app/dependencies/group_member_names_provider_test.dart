import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/group_member_name_providers.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/infrastructure/drift_contact_repository.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/authentication_harness.dart' as auth;

/// What the names of a group's members come from: this phone's contacts, the
/// directory for a member the contacts do not hold, and the stored session for
/// this account.
const _alice = '00000000-0000-0000-0000-0000000000a1';
const _bob = '00000000-0000-0000-0000-0000000000b2';
const _carol = '00000000-0000-0000-0000-0000000000c3';
const _dave = '00000000-0000-0000-0000-0000000000d4';

void main() {
  late LocalDatabase database;
  late DriftContactRepository repository;

  setUp(() {
    database = LocalDatabase(NativeDatabase.memory());
    repository = DriftContactRepository(database);
  });

  tearDown(() => database.close());

  /// A phone that holds Alice (verified, with an authenticated name) and Bob
  /// (a username only). Carol is in the directory and not in the store; Dave
  /// is in neither.
  Future<_Rig> rig({
    List<DirectoryUser> directory = const [
      DirectoryUser(userId: _alice, username: 'alice_u'),
      DirectoryUser(userId: _bob, username: 'bob_u'),
      DirectoryUser(userId: _carol, username: 'carol_u'),
    ],
    bool directoryFails = false,
    String? storedUsername = 'me_u',
  }) async {
    await repository.replaceDirectory(const [
      DirectoryUser(userId: _alice, username: 'alice_u'),
      DirectoryUser(userId: _bob, username: 'bob_u'),
    ]);
    await repository.writeProfile(
      _alice,
      ProfileCiphertext(blob: Uint8List(1024), version: 1),
      const AuthenticatedProfile(
        displayName: 'Alice Smith',
        avatarSeed: 1,
        version: 1,
        authorDeviceId: 'device',
      ),
    );
    final identity = PeerIdentityPublic(
      masterPublic: _bytes(32, 1),
      selfSigningPublic: _bytes(32, 2),
      userSigningPublic: _bytes(32, 3),
      masterSignature: _bytes(64, 4),
      version: 1,
    );
    await repository.writeTrust(
      ContactTrustRecord(
        userId: _alice,
        state: ContactTrustState.verified,
        identity: identity,
        confirmedMasterPublic: identity.masterPublic,
        attestation: UserSigningAttestation(_bytes(64, 5)),
        etag: '"devices"',
        logHeadSequence: 0,
        logHeadHash: _bytes(32, 6),
      ),
    );
    final remote = _Directory(directory, fails: directoryFails);
    final harness = _Authentication(storedUsername);
    addTearDown(harness.close);
    final container = ProviderContainer(
      overrides: [
        authenticationUseCasesProvider.overrideWithValue(harness.useCases),
        contactLocalProvider.overrideWith((ref) => repository),
        directoryServiceProvider.overrideWith(
          (ref) => DirectoryService(remote: remote, local: repository),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authenticationControllerProvider.notifier).restore();
    return _Rig(container, remote);
  }

  /// The names once [done] holds, or the last answer after a bounded wait.
  Future<GroupMemberNames> namesWhen(
    _Rig rig,
    GroupMemberNamesRequest request, {
    bool Function(GroupMemberNames names)? done,
  }) {
    final completer = Completer<GroupMemberNames>();
    GroupMemberNames? last;
    final subscription = rig.container.listen(
      groupMemberNamesProvider(request),
      (_, next) {
        final names = next.value;
        if (names == null) return;
        last = names;
        if ((done ?? (_) => true)(names) && !completer.isCompleted) {
          completer.complete(names);
        }
      },
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => last ?? const GroupMemberNames.empty(),
    );
  }

  test('a verified contact is named by the authenticated name, a contact '
      'without one by the directory username, and this account by its '
      'session', () async {
    final rig_ = await rig();
    final self = rig_.container.read(authenticationControllerProvider).userId!;

    final names = await namesWhen(
      rig_,
      GroupMemberNamesRequest([self, _alice, _bob]),
    );

    expect(names.nameOf(_alice), 'Alice Smith');
    expect(names.isVerified(_alice), isTrue);
    expect(names.nameOf(_bob), 'bob_u');
    expect(names.isVerified(_bob), isFalse);
    expect(names.nameOf(self), 'me_u');
    // Nothing was missing, so the directory was not read.
    expect(rig_.directory.reads, 0);
  });

  test(
    'a member that is not a contact is looked up in the directory',
    () async {
      final rig_ = await rig();

      final names = await namesWhen(
        rig_,
        GroupMemberNamesRequest([_alice, _carol]),
        done: (names) => names.nameOf(_carol) != null,
      );

      expect(names.nameOf(_carol), 'carol_u');
      expect(names.isVerified(_carol), isFalse);
      expect(names.nameOf(_alice), 'Alice Smith');
      expect(rig_.directory.reads, 1);
    },
  );

  test('a member nobody lists stays unnamed, and the directory is read '
      'once', () async {
    final rig_ = await rig();

    final names = await namesWhen(
      rig_,
      GroupMemberNamesRequest([_alice, _dave]),
    );
    await rig_.directory.readOnce();
    // The answer that follows the directory read.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(names.nameOf(_dave), isNull);
    expect(rig_.directory.reads, 1);
  });

  test('an unreachable directory leaves the member unnamed', () async {
    final rig_ = await rig(directoryFails: true);

    final names = await namesWhen(
      rig_,
      GroupMemberNamesRequest([_alice, _carol]),
    );
    await rig_.directory.readOnce();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(names.nameOf(_carol), isNull);
    expect(names.nameOf(_alice), 'Alice Smith');
  });
}

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

final class _Rig {
  _Rig(this.container, this.directory);

  final ProviderContainer container;
  final _Directory directory;
}

final class _Directory implements DirectoryRemotePort {
  _Directory(this.users, {required this.fails});

  final List<DirectoryUser> users;
  final bool fails;
  var reads = 0;

  /// Completes once the directory was read, or after a bounded wait.
  Future<void> readOnce() async {
    for (var wait = 0; wait < 50 && reads == 0; wait++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<Result<List<DirectoryUser>>> fetchActivatedUsers() async {
    reads += 1;
    if (fails) {
      return const Result.failure(
        TransportFailure(TransportFailureKind.offline),
      );
    }
    return Result.success(users);
  }
}

/// A stored session that holds [username], restored on a cold start.
final class _Authentication {
  _Authentication(String? username) {
    final repository = auth.WidgetAuthenticationRepository(
      loginResult: Result.success(
        AccountSessionGrant(
          accessToken: 'unused',
          accessExpiresAt: DateTime.utc(2026, 7, 28, 12),
          accessLifetime: const Duration(minutes: 10),
          userId: auth.userId,
          scope: AccountSessionScope.register,
        ),
      ),
      registrationResult: const Result.success(
        AccountRegistration(userId: auth.userId),
      ),
    );
    final session = auth.WidgetAuthenticationSession();
    final restoring = _Session(username);
    useCases = AuthenticationUseCases(
      register: RegisterAccount(repository),
      login: LoginAccount(repository, session),
      restore: RestoreAccountSession(restoring),
      logout: LogoutAccount(session),
      erase: EraseAccount(repository, session),
      lifecycle: lifecycle,
    );
  }

  final lifecycle = auth.WidgetLifecycle();
  late final AuthenticationUseCases useCases;

  Future<void> close() => lifecycle.close();
}

final class _Session implements AuthenticationSessionPort {
  _Session(this.username);

  final String? username;

  @override
  Future<Result<AccountSessionBoundary>> restore() async => Result.success(
    AccountSessionBoundary(
      userId: auth.userId,
      deviceId: '00000000-0000-0000-0000-000000000011',
      username: username,
      scope: AccountSessionScope.full,
      offline: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
