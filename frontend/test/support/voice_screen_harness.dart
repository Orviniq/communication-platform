import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_platform_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_platform_model.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The people, the room and the fakes the voice screen tests share.

const voiceSelf = '0000000a-0000-4000-8000-00000000000a';
const voiceSelfDevice = '0000000d-0000-4000-8000-00000000000a';
const voiceSara = '0000000a-0000-4000-8000-00000000000b';
const voiceSaraDevice = '0000000d-0000-4000-8000-00000000000b';
const voiceMehdi = '0000000a-0000-4000-8000-00000000000c';
const voiceMehdiDevice = '0000000d-0000-4000-8000-00000000000c';
const voiceLayla = '0000000a-0000-4000-8000-00000000000d';
const voiceRoomId =
    'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';

/// Sara is verified; Mehdi is a contact who is not; Layla is verified and in
/// no room.
const voiceContacts = [
  ContactProjection(
    userId: voiceSara,
    username: 'sara',
    trustState: ContactTrustState.verified,
  ),
  ContactProjection(
    userId: voiceMehdi,
    username: 'mehdi',
    trustState: ContactTrustState.unverified,
  ),
  ContactProjection(
    userId: voiceLayla,
    username: 'layla',
    trustState: ContactTrustState.verified,
  ),
];

VoiceRoomPeople voicePeople() =>
    VoiceRoomPeople.fromContacts(voiceSelf, voiceContacts);

RoomState voiceRoom({
  RoomLifecycle lifecycle = RoomLifecycle.active,
  String name = 'Weekly Sync',
  String? removedBy,
}) {
  final quarantined =
      lifecycle == RoomLifecycle.forkQuarantined ||
      lifecycle == RoomLifecycle.controlQuarantined;
  return RoomState(
    roomId: voiceRoomId,
    name: name,
    members: [
      RoomMember(
        userId: voiceSelf,
        membership: switch (lifecycle) {
          RoomLifecycle.removed => RoomMembershipState.removed,
          RoomLifecycle.left => RoomMembershipState.left,
          _ => RoomMembershipState.active,
        },
      ),
      RoomMember(userId: voiceSara),
      RoomMember(userId: voiceMehdi),
    ],
    controlRevision: 2,
    controlStateHash: '${'0' * 63}2',
    lifecycle: lifecycle,
    quarantineReason: quarantined ? RoomQuarantineReason.siblingControl : null,
    removedByUserId: removedBy,
  );
}

/// The microphone: each request answers the next of [answers], or grants.
final class RecordingMicrophone implements MicrophonePermissionPort {
  RecordingMicrophone(this.log, {List<MicrophonePermission>? answers})
    : answers = answers ?? [];

  final List<String> log;
  final List<MicrophonePermission> answers;

  @override
  Future<MicrophonePermission> request() async {
    log.add('microphone');
    return answers.isEmpty ? MicrophonePermission.granted : answers.removeAt(0);
  }

  @override
  Future<bool> isGranted() async => false;

  @override
  Future<void> openSettings() async => log.add('settings');
}

final class RecordingService implements VoiceCallServicePort {
  RecordingService(this.log, {this.notificationVisible = true});

  final List<String> log;
  final bool notificationVisible;
  VoiceCallServiceRefusal? refusal;

  @override
  Future<VoiceCallServiceStart> start() async {
    log.add('start');
    final refused = refusal;
    return refused == null
        ? VoiceCallServiceRunning(notificationVisible: notificationVisible)
        : VoiceCallServiceRefused(refused);
  }

  @override
  Future<void> stop() async => log.add('stop');
}

final class FixedAvailability implements VoiceAvailabilityPort {
  FixedAvailability([this.available = true]);

  bool available;

  @override
  bool get isVoiceAvailable => available;
}

/// A call whose states a test chooses. A join announces itself unless
/// [answer] says otherwise, and the call it joins holds [peers].
final class ScriptedCall implements VoiceCallPort {
  ScriptedCall(this.log);

  final List<String> log;
  final _changes = StreamController<VoiceCallState>.broadcast();
  VoiceCallState _state = VoiceCallState.idle();
  VoiceJoinOutcome answer = const VoiceJoinAnnounced();
  List<VoiceCallParticipant> peers = const [];
  final text = <VoiceRoomTextEntry>[];

  void emit(VoiceCallState state) {
    _state = state;
    _changes.add(state);
  }

  /// The call in progress in [roomId], as it stands.
  void showInCall({
    String roomId = voiceRoomId,
    List<VoiceCallParticipant>? participants,
    bool muted = false,
    bool announcing = false,
  }) {
    if (participants != null) {
      peers = participants;
    }
    emit(
      VoiceCallState(
        phase: VoiceCallPhase.inCall,
        roomId: roomId,
        participants: peers,
        roomText: text,
        muted: muted,
        announcing: announcing,
      ),
    );
  }

  @override
  VoiceCallState get state => _state;

  @override
  Stream<VoiceCallState> get states =>
      Stream<VoiceCallState>.multi((controller) {
        controller.add(_state);
        final subscription = _changes.stream.listen(controller.add);
        controller.onCancel = subscription.cancel;
      });

  @override
  Future<VoiceJoinOutcome> join(String roomId) async {
    log.add('join');
    switch (answer) {
      case VoiceJoinAnnounced():
        showInCall(roomId: roomId);
      case VoiceJoinRefused(:final reason, :final retryAt):
        emit(
          VoiceCallState(
            phase: VoiceCallPhase.ended,
            roomId: roomId,
            endReason: reason,
            retryAt: retryAt,
          ),
        );
    }
    return answer;
  }

  @override
  Future<void> leave() async {
    log.add('leave');
    emit(
      VoiceCallState(
        phase: VoiceCallPhase.ended,
        roomId: _state.roomId,
        endReason: VoiceCallEndReason.left,
      ),
    );
  }

  @override
  Future<Result<void>> sendRoomText(String value) async {
    log.add('text $value');
    text.add(
      VoiceRoomTextEntry(
        senderUserId: voiceSelf,
        senderDeviceId: voiceSelfDevice,
        text: value,
        at: DateTime.utc(2026, 10, 1),
        isOwn: true,
      ),
    );
    showInCall(roomId: _state.roomId ?? voiceRoomId, muted: _state.muted);
    return const Result.success(null);
  }

  @override
  Future<void> setMuted(bool muted) async {
    log.add('mute $muted');
    showInCall(roomId: _state.roomId ?? voiceRoomId, muted: muted);
  }

  @override
  Future<void> tryAgain(String deviceId) async => log.add('try again');
}

/// Mounts [page] on a small router that holds the voice routes around it,
/// so the screen's own navigation lands somewhere a test can see.
Future<GoRouter> pumpVoiceRoute(
  WidgetTester tester, {
  required String initialLocation,
  required Widget Function(GoRouterState state) page,
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  Size size = const Size(390, 844),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget marker(String name) => Scaffold(
    body: Center(child: Text(name, key: ValueKey('route-$name'))),
  );
  // Each level of the stack is matched on its own location: a parent's
  // builder sees the whole location in `uri`.
  bool isPage(GoRouterState state) =>
      state.matchedLocation == Uri.parse(initialLocation).path;
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/voice-rooms',
        builder: (context, state) =>
            isPage(state) ? page(state) : marker('rooms'),
        routes: [
          GoRoute(
            path: 'new',
            builder: (context, state) =>
                isPage(state) ? page(state) : marker('create'),
          ),
          GoRoute(
            path: ':roomId',
            builder: (context, state) =>
                isPage(state) ? page(state) : marker('info'),
            routes: [
              GoRoute(
                path: 'call',
                builder: (context, state) =>
                    isPage(state) ? page(state) : marker('call'),
              ),
              GoRoute(
                path: 'invite',
                builder: (context, state) =>
                    isPage(state) ? page(state) : marker('invite'),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/contacts/:userId/safety',
        builder: (context, state) => marker('safety'),
      ),
      GoRoute(
        path: '/chats/new',
        builder: (context, state) =>
            isPage(state) ? page(state) : marker('contacts'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(AppEnvironment.production),
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppDesignSystem(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Runs [work] to its end inside the test's fake time: every zero-length wait
/// and microtask it schedules runs on the next pump.
Future<T> driveToEnd<T>(WidgetTester tester, Future<T> work) async {
  late T value;
  var done = false;
  unawaited(
    work.then((result) {
      value = result;
      done = true;
    }),
  );
  for (var turn = 0; turn < 50 && !done; turn += 1) {
    await tester.pump(Duration.zero);
    if (!done) {
      await _realTurn(tester);
    }
  }
  expect(done, isTrue, reason: 'the work never finished');
  return value;
}

/// Lets everything the call has scheduled run, in fake time and in real
/// time. Cancelling a broadcast subscription completes through a future made
/// in the root zone, whose continuation waits in the real microtask queue
/// that a fake pump never drains.
Future<void> settleBothZones(WidgetTester tester) async {
  for (var turn = 0; turn < 5; turn += 1) {
    await tester.pump(Duration.zero);
    await _realTurn(tester);
  }
  await tester.pump();
}

Future<void> _realTurn(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(Duration.zero));
