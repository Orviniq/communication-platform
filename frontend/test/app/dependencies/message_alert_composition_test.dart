import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/message_alerts.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/authentication/application/authentication_use_cases.dart';
import 'package:communication_platform/features/authentication/application/ports/authentication_ports.dart';
import 'package:communication_platform/features/authentication/domain/authentication_model.dart';
import 'package:communication_platform/features/authentication/infrastructure/coordinated_authentication_session.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/notifications/application/ports/message_alert_ports.dart';
import 'package:communication_platform/features/notifications/domain/message_alert_model.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Composition-level proof that the alert path exists in the application and
/// not merely in `lib/`.
///
/// Everything between a committed row and the platform is the real thing: the
/// real controller, the real reconciler, the real Drift store, resolved through
/// the same providers `bootstrap` installs. Only the notification surface and
/// the database file are substituted, and both are genuine platform edges a
/// host test cannot have.
void main() {
  test(
    'a committed message reaches the alert path with no other stimulus',
    () async {
      final harness = await AlertCompositionHarness.create();
      addTearDown(harness.dispose);

      expect(harness.stage, MessageAlertStage.idle);
      await harness.signIn();
      expect(harness.stage, MessageAlertStage.reconciling);
      expect(harness.presenter.shown, isEmpty);

      await harness.commitIncomingMessage('m1');

      expect(harness.presenter.shown, [MessageAlertBody.oneMessage]);
      expect(await harness.alertedIds(), {'m1'});
    },
  );

  test('the marker written by the alert is the one in the database', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();
    await harness.commitIncomingMessage('m1');

    // The same row observed again - what a re-drain of an unacknowledged
    // envelope produces - announces nothing.
    await harness.touchConversation();

    expect(harness.presenter.shown, hasLength(1));
  });

  test('reading the conversation withdraws the alert', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();
    await harness.commitIncomingMessage('m1');

    await harness.markRead();

    expect(harness.presenter.hidden, greaterThanOrEqualTo(1));
  });

  test('a burst of arrivals is one alert, not one alert each', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();

    await harness.database.writeTransaction(() async {
      for (var index = 0; index < 25; index += 1) {
        await harness.insertMessage('m$index');
      }
    });
    await pumpMicrotasks();

    expect(harness.presenter.shown, hasLength(1));
    expect(harness.presenter.shown.single, MessageAlertBody.manyMessages);
    expect(await harness.alertedIds(), hasLength(25));
  });

  test('the conversation on screen is not announced', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();

    // What the chat route does while it is mounted and the application is in
    // front of the user.
    harness.container
        .read(visibleConversationProvider)
        .enter(AlertCompositionHarness.conversationId);
    await harness.commitIncomingMessage('m1');

    expect(harness.presenter.shown, isEmpty);
    expect(
      await harness.alertedIds(),
      {'m1'},
      reason: 'leaving the conversation later must not announce it',
    );
  });

  test('logout stops the alert path', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);
    await harness.signIn();

    await harness.signOut();

    expect(harness.stage, MessageAlertStage.idle);
  });

  test('a signed-out application announces nothing at all', () async {
    final harness = await AlertCompositionHarness.create();
    addTearDown(harness.dispose);

    await harness.commitIncomingMessage('m1');

    expect(harness.presenter.shown, isEmpty);
    expect(await harness.alertedIds(), isEmpty);
  });

  testWidgets('the application root is what instantiates the controller', (
    tester,
  ) async {
    final observer = RecordingProviders();
    final harness = await AlertCompositionHarness.create(
      attachContainer: false,
      observer: observer,
    );
    addTearDown(harness.dispose);

    // Parked on a route that has nothing to do with messaging. Which screen is
    // on top must never decide whether the user can be told about a message.
    await tester.pumpWidget(
      harness.scope(
        const CommunicationPlatformApp(
          environment: AppEnvironment.production,
          locale: Locale('en'),
          authenticationEnabled: true,
          initialLocation: '/login',
        ),
      ),
    );

    expect(
      observer.initialized,
      contains(messageAlertControllerProvider),
      reason:
          'building the application root - before any test reads it - is what '
          'creates the alert controller; if the root stops holding it, this is '
          'the assertion that fails',
    );
  });
}

final class AlertCompositionHarness {
  AlertCompositionHarness._({
    required this.scope,
    required this.database,
    required this.presenter,
    required this.lifecycle,
    ProviderContainer? container,
  }) : _owned = container,
       _container = container;

  static const userId = '11111111-1111-4111-8111-111111111111';
  static const deviceId = '22222222-2222-4222-8222-222222222222';
  static const conversationId = 'conversation-1';

  static Future<AlertCompositionHarness> create({
    bool attachContainer = true,
    RecordingProviders? observer,
  }) async {
    final database = LocalDatabase(NativeDatabase.memory());
    final presenter = RecordingAlertPresenter();
    final lifecycle = AuthenticationLifecycleBus();
    final session = _FakeSession();
    final overrides = [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      localDatabaseProvider.overrideWith((ref) => Future.value(database)),
      messageAlertPresenterProvider.overrideWithValue(presenter),
      currentMessagingDeviceIdProvider.overrideWith(
        (ref) => Future.value(deviceId),
      ),
      // Delivery is a separate controller with its own dependencies, and this
      // test is about alerts. Composing it would fail for want of a networking
      // foundation, which is exactly the case the alert path must survive.
      deliveryPlatformPortsProvider.overrideWithValue(
        () async => throw StateError('no platform'),
      ),
      authenticationUseCasesProvider.overrideWithValue(
        AuthenticationUseCases(
          register: RegisterAccount(_FakeAccounts()),
          login: LoginAccount(_FakeAccounts(), session),
          restore: RestoreAccountSession(session),
          logout: LogoutAccount(session),
          erase: EraseAccount(_FakeAccounts(), session),
          lifecycle: lifecycle,
        ),
      ),
    ];
    ProviderContainer? container;
    if (attachContainer) {
      container = ProviderContainer(overrides: overrides, retry: _noRetry);
      // What `CommunicationPlatformApp` does at the root.
      container.listen(
        messageAlertControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
    }
    await database
        .into(database.conversations)
        .insert(
          ConversationsCompanion.insert(
            conversationId: conversationId,
            kind: ConversationKind.direct.index,
            listProjectionCiphertext: Uint8List.fromList([1]),
            sortKey: 0,
          ),
        );
    return AlertCompositionHarness._(
      scope: (child) => ProviderScope(
        overrides: overrides,
        retry: _noRetry,
        observers: observer == null ? null : [observer],
        child: child,
      ),
      container: container,
      database: database,
      presenter: presenter,
      lifecycle: lifecycle,
    );
  }

  final Widget Function(Widget child) scope;
  final LocalDatabase database;
  final RecordingAlertPresenter presenter;
  final AuthenticationLifecycleBus lifecycle;
  final ProviderContainer? _owned;
  final ProviderContainer? _container;

  ProviderContainer get container => _container!;

  MessageAlertStage get stage => container.read(messageAlertControllerProvider);

  MessageAlertController get controller =>
      container.read(messageAlertControllerProvider.notifier);

  Future<void> signIn() async {
    await container.read(authenticationControllerProvider.notifier).restore();
    await controller.settled;
    await pumpMicrotasks();
  }

  Future<void> signOut() async {
    await container.read(authenticationControllerProvider.notifier).logout();
    await controller.settled;
    await pumpMicrotasks();
  }

  /// What the inbox transaction leaves behind: one committed, unread row.
  Future<void> commitIncomingMessage(String messageId) async {
    await database.writeTransaction(() => insertMessage(messageId));
    await pumpMicrotasks();
  }

  Future<void> insertMessage(String messageId) => database
      .into(database.messages)
      .insert(
        MessagesCompanion.insert(
          messageId: messageId,
          conversationId: conversationId,
          currentEventId: 'event-$messageId',
          projectionCiphertext: Uint8List.fromList([1]),
          status: MessageTransportState.received.index,
          revision: 0,
          createdAt: DateTime.utc(2026, 8, 21),
          unread: const Value(true),
        ),
      );

  /// A write that changes the conversation without adding a message: an edit,
  /// a reaction, a receipt, or a re-observed envelope.
  Future<void> touchConversation() async {
    await (database.update(database.conversations)
          ..where((row) => row.conversationId.equals(conversationId)))
        .write(const ConversationsCompanion(sortKey: Value(2)));
    await pumpMicrotasks();
  }

  Future<void> markRead() async {
    await (database.update(database.messages)
          ..where((row) => row.conversationId.equals(conversationId)))
        .write(const MessagesCompanion(unread: Value(false)));
    await pumpMicrotasks();
  }

  Future<Set<String>> alertedIds() async {
    final rows = await (database.select(
      database.messages,
    )..where((row) => row.alerted.equals(true))).get();
    return rows.map((row) => row.messageId).toSet();
  }

  Future<void> dispose() async {
    _owned?.dispose();
    await pumpMicrotasks();
    await lifecycle.close();
    await database.close();
  }
}

final class RecordingAlertPresenter implements MessageAlertPresenterPort {
  final List<MessageAlertBody> shown = [];
  int hidden = 0;
  MessageAlertPlatformState? state = const MessageAlertPlatformState(
    enabled: true,
    runtimePermission: true,
    rationale: false,
  );

  @override
  Future<MessageAlertPlatformState?> platformState() async => state;

  @override
  Future<MessageAlertPlatformState?> requestPermission() async => state;

  @override
  Future<void> show(MessageAlertBody body) async => shown.add(body);

  @override
  Future<void> hide() async => hidden += 1;

  @override
  Future<void> openSystemSettings() async {}
}

final class _FakeSession implements AuthenticationSessionPort {
  @override
  Future<LoginHint> readLoginHint() async => const LoginHint();

  @override
  Future<Result<AccountSessionBoundary>> acceptLogin({
    required String username,
    required AccountSessionGrant grant,
    required bool replacedKnownDevice,
  }) => restore();

  @override
  Future<Result<AccountSessionBoundary>> restore() async =>
      const Result<AccountSessionBoundary>.success(
        AccountSessionBoundary(
          userId: AlertCompositionHarness.userId,
          deviceId: AlertCompositionHarness.deviceId,
          scope: AccountSessionScope.full,
          offline: false,
        ),
      );

  @override
  Future<void> logout() async {}

  @override
  Future<void> forgetErasedAccount() async {}
}

final class _FakeAccounts implements AccountAuthenticationRepository {
  @override
  Future<Result<AccountRegistration>> register({
    required String username,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<Result<AccountSessionGrant>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async => throw UnimplementedError();

  @override
  Future<Result<void>> eraseAccount({required String password}) async =>
      throw UnimplementedError();
}

final class RecordingProviders extends ProviderObserver {
  final List<Object> initialized = [];

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    initialized.add(context.provider);
  }
}

Duration? _noRetry(int retryCount, Object error) => null;

Future<void> pumpMicrotasks() async {
  for (var index = 0; index < 32; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
