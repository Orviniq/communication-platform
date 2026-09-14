import 'dart:typed_data';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/contact_services.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/presentation/contact_profile_page.dart';
import 'package:communication_platform/features/contacts/presentation/contacts_new_page.dart';
import 'package:communication_platform/features/contacts/presentation/edit_profile_page.dart';
import 'package:communication_platform/features/contacts/presentation/safety_number_page.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('Contacts/New pages cached rows, searches, and loads more', (
    tester,
  ) async {
    final contacts = List<ContactProjection>.generate(
      45,
      (index) => ContactProjection(
        userId: '$index',
        username: 'person_${index.toString().padLeft(2, '0')}',
        trustState: ContactTrustState.unverified,
      ),
    );
    final service = DirectoryService(
      remote: const _OfflineDirectory(),
      local: const _UnusedLocal(),
    );

    await _pump(
      tester,
      ContactsNewPage(
        ownUserId: 'self',
        contacts: Stream.value(contacts),
        directoryService: service,
      ),
    );

    expect(
      find.byKey(const ValueKey('contacts-offline-cache')),
      findsOneWidget,
    );
    expect(find.text('person_00'), findsOneWidget);
    expect(find.text('person_20'), findsNothing);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('contacts-load-more')),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(find.byKey(const ValueKey('contacts-load-more')));
    await tester.pump();
    expect(find.text('person_20'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'person_44');
    await tester.pump();
    expect(find.text('person_44'), findsWidgets);
    expect(find.text('person_00'), findsNothing);
  });

  testWidgets(
    'contact profile cannot enable messaging from cached profile data',
    (tester) async {
      const contact = ContactProjection(
        userId: 'peer',
        username: 'backend_name',
        trustState: ContactTrustState.invalidDevice,
        authenticatedProfile: AuthenticatedProfile(
          displayName: 'Forged Display Name',
          avatarSeed: 8,
          version: 1,
          authorDeviceId: 'device',
        ),
      );

      await _pump(
        tester,
        const ContactProfilePage(userId: 'peer', contact: contact),
      );

      expect(find.text('backend_name'), findsWidgets);
      expect(find.text('Forged Display Name'), findsNothing);
      final messageTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Message'),
      );
      expect(messageTile.enabled, isFalse);
    },
  );

  testWidgets(
    'Safety Number uses exact master keys and explicit confirmation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final identity = _identity();
      final trust = ContactTrustRecord(
        userId: _peerId,
        state: ContactTrustState.unverified,
        identity: identity,
        logHeadSequence: 0,
        logHeadHash: Uint8List(32),
      );
      final authentication = _SafetyAuthentication(trust);
      final local = _TrustLocal(trust);

      await _pump(
        tester,
        SafetyNumberPage(
          userId: _peerId,
          authentication: authentication,
          local: local,
        ),
        locale: const Locale('fa'),
      );

      expect(
        tester
            .widget<Directionality>(find.byType(Directionality).first)
            .textDirection,
        TextDirection.rtl,
      );
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        SafetyFingerprint(_bytes(32, 17)).qrValue,
        startsWith('CP-SAFETY-V1:'),
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('safety-qr')))
            .getSemanticsData()
            .flagsCollection
            .isImage,
        isTrue,
      );
      final confirm = find.byKey(const ValueKey('safety-confirm'));
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.widget<AppButton>(confirm).onPressed, isNull);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(tester.widget<AppButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(
        authentication.confirmedMaster,
        orderedEquals(identity.masterPublic),
      );
      expect(authentication.trust.state, ContactTrustState.verified);
      semantics.dispose();
    },
  );

  testWidgets('invalid device state exposes no confirmation bypass', (
    tester,
  ) async {
    final trust = ContactTrustRecord(
      userId: _peerId,
      state: ContactTrustState.invalidDevice,
      identity: _identity(),
    );

    await _pump(
      tester,
      SafetyNumberPage(
        userId: _peerId,
        authentication: _SafetyAuthentication(trust),
        local: _TrustLocal(trust),
      ),
    );

    expect(
      find.byKey(const ValueKey('safety-state-invalidDevice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('safety-confirm')), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('Edit Profile is localized and remains usable in RTL', (
    tester,
  ) async {
    await _pump(
      tester,
      EditProfilePage(
        service: ProfileService(
          remote: const _UnusedProfileRemote(),
          local: const _UnusedLocal(),
          authentication: const _UnusedAuthentication(),
          protection: const _UnusedProtection(),
          keyDistribution: const _UnusedDistribution(),
        ),
      ),
      locale: const Locale('fa'),
    );

    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection,
      TextDirection.rtl,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(AppButton), findsOneWidget);
  });

  testWidgets('a build with no profile adapter says so and offers no Save', (
    tester,
  ) async {
    // Every flavor but development composes the unsupported profile
    // ports, so a production build cannot publish a profile. It used to
    // claim a "development-only fake transport" instead and let the user
    // press Save into a generic error (ADR-045).
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      const EditProfilePage(),
      environment: AppEnvironment.production,
    );

    expect(
      find.byKey(const ValueKey('profile-not-built-notice')),
      findsOneWidget,
    );
    expect(find.text('Not built yet'), findsOneWidget);
    expect(find.textContaining('cannot publish a profile yet'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('development-profile-transport-warning')),
      findsNothing,
    );
    expect(
      tester
          .widget<AppButton>(find.byKey(const ValueKey('profile-save')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('the development stand-in keeps its own distinct wording', (
    tester,
  ) async {
    await _pump(tester, const EditProfilePage());

    expect(
      find.byKey(const ValueKey('development-profile-transport-warning')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-not-built-notice')),
      findsNothing,
    );
  });

  test('publishing support is read from the composed adapters', () {
    ProfilePublishing publishingIn(AppEnvironment environment) {
      final container = ProviderContainer(
        overrides: [appEnvironmentProvider.overrideWithValue(environment)],
      );
      addTearDown(container.dispose);
      return container.read(profilePublishingProvider);
    }

    expect(
      publishingIn(AppEnvironment.development),
      ProfilePublishing.developmentStandIn,
    );
    expect(publishingIn(AppEnvironment.production), ProfilePublishing.notBuilt);
    expect(ProfilePublishing.notBuilt.canPublish, isFalse);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  AppEnvironment environment = AppEnvironment.development,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appEnvironmentProvider.overrideWithValue(environment)],
      child: MaterialApp(
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppDesignSystem(child: child ?? const SizedBox.shrink()),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _peerId = '11111111-1111-4111-8111-111111111111';

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List<int>.filled(length, value));

PeerIdentityPublic _identity() => PeerIdentityPublic(
  masterPublic: _bytes(32, 1),
  selfSigningPublic: _bytes(32, 2),
  userSigningPublic: _bytes(32, 3),
  masterSignature: _bytes(64, 4),
  version: 1,
);

final class _OfflineDirectory implements DirectoryRemotePort {
  const _OfflineDirectory();

  @override
  Future<Result<List<DirectoryUser>>> fetchActivatedUsers() async =>
      const Result.failure(TransportFailure(TransportFailureKind.offline));
}

final class _TrustLocal extends _UnusedLocal {
  const _TrustLocal(this.trust);

  final ContactTrustRecord trust;

  @override
  Future<Result<ContactTrustRecord?>> readTrust(String userId) async =>
      Result.success(trust);
}

final class _SafetyAuthentication implements PeerAuthenticationService {
  _SafetyAuthentication(this.trust);

  ContactTrustRecord trust;
  Uint8List? confirmedMaster;

  @override
  Future<Result<AuthenticatedPeer>> refreshPeer({
    required String userId,
    required bool requirePrekeys,
  }) async =>
      const Result.failure(SecurityFailure(SecurityFailureKind.policyBlocked));

  @override
  Future<Result<SafetyFingerprint>> safetyFingerprint(String userId) async =>
      Result.success(SafetyFingerprint(_bytes(32, 17)));

  @override
  Future<Result<ContactTrustRecord>> confirmOutOfBand({
    required String userId,
    required Uint8List exactMasterPublic,
  }) async {
    confirmedMaster = Uint8List.fromList(exactMasterPublic);
    trust = trust.copyWith(state: ContactTrustState.verified);
    return Result.success(trust);
  }
}

class _UnusedLocal implements ContactLocalPort {
  const _UnusedLocal();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedProfileRemote implements ProfileRemotePort {
  const _UnusedProfileRemote();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedAuthentication implements PeerAuthenticationService {
  const _UnusedAuthentication();

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedProtection implements ProfileProtectionPort {
  const _UnusedProtection();

  @override
  bool get isProductionReady => false;

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}

final class _UnusedDistribution implements ProfileKeyDistributionPort {
  const _UnusedDistribution();

  @override
  bool get isProductionReady => false;

  @override
  Never noSuchMethod(Invocation invocation) => throw StateError('unused');
}
