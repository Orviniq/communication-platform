import 'dart:async';

import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/server_config_limits.dart';
import 'package:communication_platform/app/dependencies/voice_call_providers.dart';
import 'package:communication_platform/app/dependencies/voice_call_service_providers.dart';
import 'package:communication_platform/app/dependencies/voice_room_providers.dart';
import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/features/server_config/domain/server_config_model.dart';
import 'package:communication_platform/features/voice/application/room_use_cases.dart';
import 'package:communication_platform/features/voice/application/voice_call_controller.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/domain/voice_room_text_budget.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';
import 'package:communication_platform/features/voice/presentation/voice_call_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/voice/support/call_fakes.dart';
import '../support/voice_screen_harness.dart';

const _sara = VoiceCallParticipant(
  userId: voiceSara,
  deviceId: voiceSaraDevice,
  status: VoiceParticipantStatus.connected,
);
const _mehdi = VoiceCallParticipant(
  userId: voiceMehdi,
  deviceId: voiceMehdiDevice,
  status: VoiceParticipantStatus.connected,
);

void main() {
  late List<String> log;
  late ScriptedCall call;

  setUp(() {
    log = [];
    call = ScriptedCall(log);
  });

  VoiceCallController controllerWith({
    List<MicrophonePermission>? answers,
    VoiceCallServiceRefusal? serviceRefusal,
    bool notificationVisible = true,
    bool available = true,
  }) {
    final controller = VoiceCallController(
      call: call,
      microphone: RecordingMicrophone(log, answers: answers),
      service: RecordingService(log, notificationVisible: notificationVisible)
        ..refusal = serviceRefusal,
      availability: FixedAvailability(available),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpCall(
    WidgetTester tester,
    VoiceCallController controller, {
    RoomState? room,
    VoiceRoomPeople? people,
    String roomId = voiceRoomId,
    bool voiceAvailable = true,
    bool signallingConnected = true,
    bool offline = false,
    Set<int> buckets = const {1024, 4096, 16384},
    Locale locale = const Locale('en'),
    TextScaler textScaler = TextScaler.noScaling,
    Size size = const Size(390, 844),
  }) => pumpVoiceRoute(
    tester,
    initialLocation: '/voice-rooms/$roomId/call',
    locale: locale,
    textScaler: textScaler,
    size: size,
    page: (_) => VoiceCallView(
      roomId: roomId,
      room: room ?? voiceRoom(),
      controller: controller,
      people: people ?? voicePeople(),
      signalBuckets: buckets,
      voiceAvailable: voiceAvailable,
      signallingConnected: signallingConnected,
      offline: offline,
    ),
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  group('the join', () {
    testWidgets('opening the call asks for nothing, a denial blocks the join, '
        'and a grant starts the service before the join', (tester) async {
      final controller = controllerWith(answers: [MicrophonePermission.denied]);
      await pumpCall(tester, controller);

      expect(log, isEmpty, reason: 'opening the screen asks for nothing');
      expect(find.text('Join the call?'), findsOneWidget);

      await tapVisible(tester, key('voice-call-join'));
      expect(log, ['microphone']);
      expect(find.text('Microphone access is off'), findsOneWidget);
      expect(find.textContaining('Nothing was sent.'), findsOneWidget);
      expect(key('voice-call-open-settings'), findsNothing);
      expect(key('voice-call-mute'), findsNothing);

      await tapVisible(tester, key('voice-call-try-again'));
      expect(log, ['microphone', 'microphone', 'start', 'join']);
      expect(key('voice-call-mute'), findsOneWidget);
    });

    testWidgets('a permanent denial points to the system settings', (
      tester,
    ) async {
      final controller = controllerWith(
        answers: [MicrophonePermission.deniedPermanently],
      );
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));
      expect(find.textContaining('system settings'), findsOneWidget);
      await tapVisible(tester, key('voice-call-open-settings'));

      expect(log, ['microphone', 'settings']);
    });

    testWidgets('a service that does not start keeps the call from starting', (
      tester,
    ) async {
      final controller = controllerWith(
        serviceRefusal: VoiceCallServiceRefusal.notInForeground,
      );
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));

      expect(log, ['microphone', 'start']);
      expect(find.text('The call could not start'), findsOneWidget);
      expect(
        find.textContaining('only while this app is on screen'),
        findsOneWidget,
      );
    });

    testWidgets('notifications that are off are a stated outcome', (
      tester,
    ) async {
      final controller = controllerWith(notificationVisible: false);
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));

      expect(key('voice-call-notification-hidden'), findsOneWidget);
      expect(key('voice-call-mute'), findsOneWidget);
    });
  });

  group('the live room', () {
    testWidgets('shows the participants, mutes, and says the audio crosses a '
        'relay', (tester) async {
      final semantics = tester.ensureSemantics();
      call.peers = [
        _sara,
        const VoiceCallParticipant(
          userId: voiceMehdi,
          deviceId: voiceMehdiDevice,
          status: VoiceParticipantStatus.connecting,
        ),
      ];
      final controller = controllerWith();
      await pumpCall(tester, controller);
      expect(key('voice-call-relay-note'), findsNothing);
      expect(
        find.textContaining("crosses this server's relay"),
        findsOneWidget,
        reason: 'stated before the join as well',
      );

      await tapVisible(tester, key('voice-call-join'));

      expect(key('voice-call-count'), findsOneWidget);
      expect(find.text('3 in the call'), findsOneWidget);
      expect(find.text('sara'), findsOneWidget);
      expect(find.text('mehdi'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Connecting'), findsOneWidget);
      expect(key('voice-call-relay-note'), findsOneWidget);
      expect(
        tester.getSemantics(key('voice-call-mute')),
        isSemantics(
          isButton: true,
          label: 'Mute',
          value: 'Your microphone is on',
        ),
      );

      await tapVisible(tester, key('voice-call-mute'));

      expect(log.last, 'mute true');
      expect(find.text('Unmute'), findsOneWidget);
      expect(
        find.descendant(
          of: key('voice-call-own-tile'),
          matching: find.text('Muted'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(key('voice-call-mute')).value,
        'You are muted',
      );
      semantics.dispose();
    });

    testWidgets('a leave closes the call, stops the service and goes back', (
      tester,
    ) async {
      call.peers = [_sara];
      final controller = controllerWith();
      await pumpCall(tester, controller);
      await tapVisible(tester, key('voice-call-join'));
      log.clear();

      await tapVisible(tester, key('voice-call-leave'));

      expect(log, ['leave', 'stop']);
      expect(key('route-info'), findsOneWidget);
    });

    testWidgets('alone in the call, it says so and offers an invitation', (
      tester,
    ) async {
      final controller = controllerWith();
      await pumpCall(tester, controller);
      await tapVisible(tester, key('voice-call-join'));

      expect(key('voice-call-alone'), findsOneWidget);
      expect(find.text('1 in the call'), findsOneWidget);
    });
  });

  group('honest states', () {
    testWidgets('a device not reachable after the bounded retries says so on '
        'its own tile, and Try again asks again', (tester) async {
      final semantics = tester.ensureSemantics();
      call.peers = [
        const VoiceCallParticipant(
          userId: voiceSara,
          deviceId: voiceSaraDevice,
          status: VoiceParticipantStatus.notReachable,
        ),
        _mehdi,
      ];
      final controller = controllerWith();
      await pumpCall(tester, controller);
      await tapVisible(tester, key('voice-call-join'));

      final tile = key('voice-call-tile-$voiceSaraDevice');
      expect(
        find.descendant(of: tile, matching: find.text('Not reachable')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(tile),
        isSemantics(
          label: 'sara, Not reachable',
          isLiveRegion: true,
          isButton: true,
        ),
      );
      // Only that tile: the others carry on, and the call is not broken.
      expect(
        find.descendant(
          of: key('voice-call-tile-$voiceMehdiDevice'),
          matching: find.text('Connected'),
        ),
        findsOneWidget,
      );
      expect(find.text('2 in the call'), findsOneWidget);

      await tapVisible(tester, key('voice-call-tile-try-$voiceSaraDevice'));
      expect(log.last, 'try again');
      semantics.dispose();
    });

    testWidgets('a call already holding ten states the ceiling and why', (
      tester,
    ) async {
      call.answer = const VoiceJoinRefused(VoiceCallEndReason.callFull);
      final controller = controllerWith();
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));

      expect(find.text('This call is full'), findsOneWidget);
      expect(
        find.textContaining(
          'a call holds ten at most, because every phone sends its audio to '
          'every other phone',
        ),
        findsOneWidget,
      );
      expect(log, ['microphone', 'start', 'join', 'stop']);
      expect(key('voice-call-try-again'), findsOneWidget);
    });

    testWidgets('a connection down while the audio continues marks room text '
        'and presence stale', (tester) async {
      call
        ..peers = [_sara]
        ..text.add(
          VoiceRoomTextEntry(
            senderUserId: voiceSara,
            senderDeviceId: voiceSaraDevice,
            text: 'Can everyone hear me?',
            at: DateTime.utc(2026, 10, 1),
            isOwn: false,
          ),
        );
      final controller = controllerWith();
      await pumpCall(tester, controller, signallingConnected: false);
      await tapVisible(tester, key('voice-call-join'));

      expect(key('voice-call-socket-degraded'), findsOneWidget);
      expect(find.textContaining('Audio is fine.'), findsOneWidget);
      expect(find.text('2 in the call · last known'), findsOneWidget);
      // The audio is not interrupted: the tile still reads connected.
      expect(find.text('Connected'), findsOneWidget);

      await tapVisible(tester, key('voice-call-tab-chat'));
      expect(key('voice-room-text-stale'), findsOneWidget);
      expect(find.text('Can everyone hear me?'), findsOneWidget);
      expect(find.text('Chat unavailable'), findsOneWidget);
      expect(key('voice-room-text-field'), findsNothing);
    });

    testWidgets('an ICE restart in progress shows on its tile', (tester) async {
      final semantics = tester.ensureSemantics();
      call.peers = [
        const VoiceCallParticipant(
          userId: voiceSara,
          deviceId: voiceSaraDevice,
          status: VoiceParticipantStatus.connected,
          restartingIce: true,
        ),
      ];
      final controller = controllerWith();
      await pumpCall(tester, controller);
      await tapVisible(tester, key('voice-call-join'));

      expect(find.text('Renewing its connection'), findsOneWidget);
      expect(
        tester.getSemantics(key('voice-call-tile-$voiceSaraDevice')).label,
        'sara, Renewing its connection',
      );
      await tapVisible(tester, key('voice-call-tile-$voiceSaraDevice'));
      expect(
        find.textContaining('The audio keeps its old path meanwhile.'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('a changed safety number stops that tile only, and routes to '
        'verify', (tester) async {
      call.peers = [
        const VoiceCallParticipant(
          userId: voiceSara,
          deviceId: voiceSaraDevice,
          status: VoiceParticipantStatus.identityBlocked,
        ),
        _mehdi,
      ];
      final controller = controllerWith();
      await pumpCall(tester, controller);
      await tapVisible(tester, key('voice-call-join'));

      expect(find.text('Safety number changed'), findsOneWidget);
      await tapVisible(tester, key('voice-call-tile-verify-$voiceSaraDevice'));
      expect(key('route-safety'), findsOneWidget);
    });

    testWidgets('an eleventh participant sees the refusal and its reason', (
      tester,
    ) async {
      final mesh = CallMesh(accounts: 11);
      final ten = [
        for (var index = 0; index < 10; index += 1) mesh.device(index),
      ];
      await driveToEnd(tester, mesh.joinAll(ten));
      for (final device in ten) {
        expect(device.state.phase, VoiceCallPhase.inCall);
        expect(device.state.devicesInCall, 10);
      }
      final eleventh = mesh.device(10);
      final controller = VoiceCallController(
        call: eleventh.engine,
        microphone: RecordingMicrophone(log),
        service: RecordingService(log),
        availability: FixedAvailability(),
      );
      await pumpCall(
        tester,
        controller,
        roomId: callRoomId,
        room: mesh.room.stateFor(eleventh.userId),
        people: VoiceRoomPeople(currentUserId: eleventh.userId),
      );

      await tester.ensureVisible(key('voice-call-join'));
      await tester.tap(key('voice-call-join'));
      // Long enough for the button's press feedback; the call keeps its own
      // clock, which only the mesh moves.
      await tester.pump(const Duration(milliseconds: 200));
      // The first answer window: the ten answer the query, and the join sees
      // the call is full before it announces itself.
      await driveToEnd(tester, mesh.clock.elapse(const Duration(seconds: 3)));
      await settleBothZones(tester);

      expect(find.text('This call is full'), findsOneWidget);
      expect(
        find.textContaining('Ten people are already in it'),
        findsOneWidget,
      );
      expect(log, ['microphone', 'start', 'stop']);
      expect(
        mesh.network.framesOf(VoiceSignalKind.join, from: eleventh.deviceId),
        isEmpty,
      );
      for (final device in ten) {
        expect(device.state.devicesInCall, 10);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await driveToEnd(tester, controller.dispose());
      await driveToEnd(tester, mesh.dispose());
    });
  });

  group('a server with no voice', () {
    testWidgets('offers no call control and asks for nothing', (tester) async {
      final controller = controllerWith(available: false);
      await pumpCall(tester, controller, voiceAvailable: false);

      expect(find.text('Voice is not set up on this server'), findsOneWidget);
      expect(key('voice-call-join'), findsNothing);
      expect(key('voice-call-try-again'), findsNothing);
      expect(key('voice-call-mute'), findsNothing);
      expect(log, isEmpty);
    });

    testWidgets('a relay that answers 503 is final, and offers no retry', (
      tester,
    ) async {
      call.answer = const VoiceJoinRefused(VoiceCallEndReason.voiceUnavailable);
      final controller = controllerWith();
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));

      expect(find.text('Voice is not set up on this server'), findsOneWidget);
      expect(key('voice-call-try-again'), findsNothing);
      expect(key('voice-call-join'), findsNothing);
      expect(log, ['microphone', 'start', 'join', 'stop']);
    });
  });

  group('a room that cannot hold a call', () {
    testWidgets('a paused room offers no join and says what waits, without '
        'naming a conflict it does not have', (tester) async {
      final controller = controllerWith();
      await pumpCall(
        tester,
        controller,
        room: voiceRoom(lifecycle: RoomLifecycle.controlQuarantined),
      );

      expect(key('voice-call-room-paused'), findsOneWidget);
      expect(find.text('Joining is paused'), findsOneWidget);
      expect(
        find.textContaining('A change to this room could not be accepted'),
        findsOneWidget,
      );
      expect(find.textContaining('conflicting'), findsNothing);
      expect(key('voice-call-join'), findsNothing);
      expect(log, isEmpty);
    });

    testWidgets('a join the room refuses stops the service and offers no '
        'retry', (tester) async {
      call.answer = const VoiceJoinRefused(VoiceCallEndReason.roomQuarantined);
      final controller = controllerWith();
      await pumpCall(tester, controller);

      await tapVisible(tester, key('voice-call-join'));

      expect(find.text('Joining is paused'), findsOneWidget);
      expect(
        find.textContaining('until its members settle a change'),
        findsOneWidget,
      );
      expect(key('voice-call-try-again'), findsNothing);
      expect(log, ['microphone', 'start', 'join', 'stop']);
    });
  });

  group('room text', () {
    testWidgets('the composer refuses a line the largest bucket cannot carry', (
      tester,
    ) async {
      const buckets = {1024};
      final controller = controllerWith();
      await pumpCall(tester, controller, buckets: buckets);
      await tapVisible(tester, key('voice-call-join'));
      await tapVisible(tester, key('voice-call-tab-chat'));
      expect(find.textContaining('Temporary and best-effort.'), findsOneWidget);
      expect(find.textContaining('Nothing said yet.'), findsOneWidget);

      final long = 'x' * 900;
      final expected =
          VoiceRoomTextBudget.check(long, buckets) as VoiceRoomTextTooLong;
      await tester.enterText(key('voice-room-text-field'), long);
      await tester.pump();

      expect(
        find.text(
          'That message is too long to send. Shorten it by '
          '${expected.excessScalars} characters.',
        ),
        findsOneWidget,
      );
      AppIconButton send() =>
          tester.widget<AppIconButton>(key('voice-room-text-send'));
      expect(send().onPressed, isNull);

      await tester.enterText(key('voice-room-text-field'), 'hello');
      await tester.pump();
      expect(send().onPressed, isNotNull);
      await tapVisible(tester, key('voice-room-text-send'));

      expect(log.last, 'text hello');
      expect(find.text('hello'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('voice-room-text-field')).controller!.text,
        isEmpty,
      );
    });
  });

  group('layout and accessibility', () {
    testWidgets('narrow Persian at twice the text size keeps Mute and Leave on '
        'screen', (tester) async {
      call.peers = [_sara, _mehdi];
      final controller = controllerWith();
      await pumpCall(
        tester,
        controller,
        locale: const Locale('fa'),
        textScaler: const TextScaler.linear(2),
        size: const Size(360, 800),
      );
      await tapVisible(tester, key('voice-call-join'));

      expect(tester.takeException(), isNull);
      expect(
        Directionality.of(tester.element(key('voice-call-screen'))),
        TextDirection.rtl,
      );
      expect(key('voice-call-mute').hitTestable(), findsOneWidget);
      expect(key('voice-call-leave').hitTestable(), findsOneWidget);
    });

    testWidgets('a wide window puts room text beside the tiles, and resizing '
        'keeps the call and the draft', (tester) async {
      call.peers = [_sara];
      final controller = controllerWith();
      await pumpCall(tester, controller, size: const Size(1280, 800));
      await tapVisible(tester, key('voice-call-join'));

      expect(key('voice-room-text-panel'), findsOneWidget);
      expect(key('voice-call-tab-chat'), findsNothing);
      await tester.enterText(key('voice-room-text-field'), 'half a thought');

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(key('voice-call-mute'), findsOneWidget);
      expect(key('voice-call-tab-chat'), findsOneWidget);
      await tapVisible(tester, key('voice-call-tab-chat'));
      expect(find.text('half a thought'), findsOneWidget);
      expect(log, ['microphone', 'start', 'join']);
    });
  });

  testWidgets('from start-up to a call, nothing asks for the microphone until '
      'the user starts one, and the shell returns to the call', (tester) async {
    call.peers = [_sara];
    final controller = controllerWith();
    final room = voiceRoom();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
          publishedLimitsProvider.overrideWithValue(ServerConfig.fallback),
          voiceScopeProvider.overrideWith(
            (ref) => (userId: voiceSelf, deviceId: voiceSelfDevice),
          ),
          voiceRoomsProvider.overrideWith((ref) => Stream.value([room])),
          voiceRoomProvider.overrideWith(
            (ref, roomId) => Stream.value(roomId == voiceRoomId ? room : null),
          ),
          contactListProvider.overrideWith(
            (ref, userId) => Stream.value(voiceContacts),
          ),
          roomUseCasesProvider.overrideWith(
            (ref) => Completer<RoomUseCases>().future,
          ),
          voiceCallControllerProvider.overrideWith((ref, scope) {
            // As the composition does: the shell learns of the call from the
            // mirror, never by composing one.
            final following = call.states.listen(
              ref.read(voiceCallMirrorProvider.notifier).follow,
            );
            ref.onDispose(following.cancel);
            return controller;
          }),
          voiceAvailabilityProvider.overrideWithValue(true),
          voiceOfflineProvider.overrideWithValue(false),
          voiceSignallingConnectedProvider.overrideWithValue(true),
        ],
        child: const CommunicationPlatformApp(
          environment: AppEnvironment.production,
          locale: Locale('en'),
          themeMode: ThemeMode.light,
          initialLocation: '/voice-rooms',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Weekly Sync'), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
    expect(log, isEmpty, reason: 'start-up and the room list ask for nothing');

    await tester.tap(key('voice-room-row-$voiceRoomId'));
    await tester.pumpAndSettle();
    expect(key('voice-room-info-screen'), findsOneWidget);
    expect(log, isEmpty, reason: "nor does the room's info");

    await tapVisible(tester, key('voice-room-start-call'));
    expect(log, ['microphone', 'start', 'join']);
    expect(key('voice-call-mute'), findsOneWidget);
    expect(key('active-voice-banner'), findsNothing);

    // Minimized, the call goes on, and the shell offers the way back.
    await tapVisible(tester, key('voice-call-minimize'));
    expect(key('voice-room-info-screen'), findsOneWidget);
    expect(find.text('Live now · 2'), findsOneWidget);
    expect(find.text('Return to voice room: Weekly Sync'), findsOneWidget);
    await tapVisible(tester, key('active-voice-banner'));
    expect(key('voice-call-mute'), findsOneWidget);

    await tapVisible(tester, key('voice-call-leave'));
    expect(log, ['microphone', 'start', 'join', 'leave', 'stop']);
    expect(key('active-voice-banner'), findsNothing);
  });
}
