import 'dart:async';
import 'dart:io';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/attachment_providers.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/local_storage/infrastructure/database/local_database.dart';
import 'package:communication_platform/features/messaging/application/conversation_timeline.dart';
import 'package:communication_platform/features/messaging/domain/conversation_model.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/authentication_harness.dart';
import '../support/voice_screen_harness.dart';

// Wide enough that the confirmation wraps to a height the test view can hold:
// the test font is far wider than the real one.
const _size = Size(800, 1000);

/// Log out through the real router.
///
/// The confirmation dialog is pushed on the root navigator, and Settings sits
/// on the navigator of its tab. A button that closed the dialog with a bare
/// `Navigator.pop` popped the tab instead, the dialog never answered, and
/// logging out did nothing. `settings_surfaces_test.dart` mounts the page
/// alone, with one navigator, so it could not see that.
void main() {
  testWidgets('Cancel closes the dialog and Settings stays', (tester) async {
    final (:container, :harness) = await _pumpApp(
      tester,
      size: _size,
      initialLocation: '/settings',
    );

    await _openConfirmation(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(find.text('Log out of this device?'), findsNothing);
    expect(find.byKey(const ValueKey('settings-log-out')), findsOneWidget);
    expect(harness.session.logouts, 0);
    expect(
      container.read(authenticationControllerProvider).access,
      isNot(AuthenticationRouteAccess.signedOut),
    );
  });

  testWidgets('confirming closes the dialog and logs the session out', (
    tester,
  ) async {
    final (:container, :harness) = await _pumpApp(
      tester,
      size: _size,
      initialLocation: '/settings',
    );

    await _openConfirmation(tester);
    await tester.tap(find.text('Log out and erase'));
    await _settle(tester);

    expect(find.text('Log out of this device?'), findsNothing);
    expect(harness.session.logouts, 1);
    expect(
      container.read(authenticationControllerProvider).access,
      AuthenticationRouteAccess.signedOut,
    );
    // The application's route guard is not composed in this harness, so
    // whether it then leaves Settings is not asked here: what is asked is that
    // the answer of the dialog reaches the log out at all.
  });
}

/// Brings the Log out row into view and opens its confirmation.
Future<void> _openConfirmation(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('settings-log-out'));
  await tester.scrollUntilVisible(
    row,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(row);
  await _settle(tester);
  await tester.tap(row);
  await _settle(tester);
  expect(find.text('Log out of this device?'), findsOneWidget);
}

/// Long enough for a route transition and for the projections to answer. A
/// page still loading shows a spinner, which never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<({ProviderContainer container, AuthenticationHarness harness})> _pumpApp(
  WidgetTester tester, {
  required Size size,
  String initialLocation = '/chats',
  List<ConversationSummary> summaries = const [],
  bool privateCache = true,
  Locale locale = const Locale('en'),
  List<Override> extra = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final harness = AuthenticationHarness();
  addTearDown(harness.close);
  final container = ProviderContainer(
    overrides: [
      appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
      authenticationUseCasesProvider.overrideWithValue(harness.useCases),
      localDatabaseProvider.overrideWith(
        (ref) => Completer<LocalDatabase>().future,
      ),
      conversationSummariesProvider.overrideWith(
        (ref, userId) => Stream.value(summaries),
      ),
      conversationMessagesProvider.overrideWith(
        (ref, request) => Stream.value(
          const ConversationTimelineState(
            page: ConversationMessagePage.empty,
            loadingBefore: false,
            olderLoadFailed: false,
          ),
        ),
      ),
      contactListProvider.overrideWith((ref, userId) => Stream.value(const [])),
      // A verified peer, so a direct chat's composer takes text.
      contactProvider.overrideWith(
        (ref, userId) => Stream.value(
          ContactProjection(
            userId: userId,
            username: userId,
            trustState: ContactTrustState.verified,
          ),
        ),
      ),
      voiceRoomsProvider.overrideWith((ref) => Stream.value(const [])),
      // A private cache, so a direct chat's paperclip is enabled. Nothing
      // here writes to it.
      attachmentCacheRootProvider.overrideWith(
        (ref) => privateCache
            ? Future.value(Directory.systemTemp)
            : Future.error(StateError('no private cache')),
      ),
      // The test room, as its info page and the banner read it.
      voiceScopeProvider.overrideWith(
        (ref) => (userId: voiceSelf, deviceId: voiceSelfDevice),
      ),
      voiceRoomProvider.overrideWith(
        (ref, roomId) =>
            Stream.value(roomId == voiceRoomId ? voiceRoom() : null),
      ),
      roomUseCasesProvider.overrideWith(
        (ref) => Completer<RoomUseCases>().future,
      ),
      voiceCallControllerProvider.overrideWith(
        (ref, scope) => Completer<VoiceCallController>().future,
      ),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  final signedIn = await container
      .read(authenticationControllerProvider.notifier)
      .login(username: 'reader', password: 'correct horse battery');
  expect(signedIn, isTrue);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: locale,
        themeMode: ThemeMode.light,
        initialLocation: initialLocation,
      ),
    ),
  );
  await _settle(tester);
  return (container: container, harness: harness);
}
