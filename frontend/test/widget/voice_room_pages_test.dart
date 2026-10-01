import 'package:communication_platform/app/dependencies/voice_screen_providers.dart';
import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/presentation/contacts_new_page.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/presentation/create_voice_room_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_invite_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_view_models.dart';
import 'package:communication_platform/features/voice/presentation/voice_rooms_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/voice_screen_harness.dart';

const _otherRoomId =
    'abc0000000000000000000000000000000000000000000000000000000000001';
const _waitingRoomId =
    'abc0000000000000000000000000000000000000000000000000000000000002';
const _leftRoomId =
    'abc0000000000000000000000000000000000000000000000000000000000003';

RoomState _otherRoom({
  required String roomId,
  required String name,
  RoomLifecycle lifecycle = RoomLifecycle.active,
}) => RoomState(
  roomId: roomId,
  name: name,
  members: [
    RoomMember(
      userId: voiceSelf,
      membership: lifecycle == RoomLifecycle.left
          ? RoomMembershipState.left
          : RoomMembershipState.active,
    ),
    RoomMember(userId: voiceSara),
  ],
  controlRevision: 1,
  controlStateHash: '${'0' * 63}1',
  lifecycle: lifecycle,
);

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

AppButton _button(WidgetTester tester, String key) =>
    tester.widget<AppButton>(_key(key));

void main() {
  group('the room list', () {
    testWidgets('each room has a state line, the call\'s room comes first, and '
        'a row opens the room', (tester) async {
      final rows = VoiceRoomRow.fromRooms(
        [
          _otherRoom(roomId: _otherRoomId, name: 'Design Review'),
          _otherRoom(
            roomId: _waitingRoomId,
            name: 'Ad Hoc',
            lifecycle: RoomLifecycle.stateRecoveryRequired,
          ),
          _otherRoom(
            roomId: _leftRoomId,
            name: 'Release Cut',
            lifecycle: RoomLifecycle.left,
          ),
          voiceRoom(),
        ],
        callRoomId: voiceRoomId,
        callDevices: 3,
      );
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms',
        page: (_) => VoiceRoomsView(rows: rows),
      );

      expect(find.text('Live now · 3'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('Asking a member for its state'), findsOneWidget);
      expect(find.text('You left this room'), findsOneWidget);
      final order = [
        for (final name in ['Weekly Sync', 'Design Review', 'Ad Hoc'])
          tester.getTopLeft(find.text(name)).dy,
      ];
      expect(order, orderedEquals([...order]..sort()));

      await _tapVisible(tester, _key('voice-room-row-$_otherRoomId'));
      expect(_key('route-info'), findsOneWidget);
    });

    testWidgets('an empty list offers to create a room', (tester) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms',
        page: (_) => const VoiceRoomsView(rows: []),
      );

      expect(find.text('No voice rooms yet'), findsOneWidget);
      await _tapVisible(tester, find.text('Create a room'));
      expect(_key('route-create'), findsOneWidget);
    });

    testWidgets('a server with no voice offers no room to create', (
      tester,
    ) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms',
        page: (_) => const VoiceRoomsView(rows: [], voiceAvailable: false),
      );

      expect(find.text('This server does not offer voice'), findsOneWidget);
      expect(find.text('Create a room'), findsNothing);
    });

    testWidgets('offline, it keeps the saved rooms and says calls wait', (
      tester,
    ) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms',
        page: (_) => VoiceRoomsView(
          rows: VoiceRoomRow.fromRooms([voiceRoom()]),
          offline: true,
        ),
      );

      expect(_key('voice-rooms-offline'), findsOneWidget);
      expect(find.text('Weekly Sync'), findsOneWidget);
    });

    testWidgets('Persian at twice the text size lays out right to left', (
      tester,
    ) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms',
        locale: const Locale('fa'),
        textScaler: const TextScaler.linear(2),
        size: const Size(360, 800),
        page: (_) => VoiceRoomsView(
          rows: VoiceRoomRow.fromRooms([voiceRoom(name: 'جلسهٔ هفتگی')]),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        Directionality.of(tester.element(_key('voice-rooms-screen'))),
        TextDirection.rtl,
      );
      expect(find.text('جلسهٔ هفتگی'), findsOneWidget);
      expect(find.text('خالی'), findsOneWidget);
    });
  });

  group('creating a room', () {
    testWidgets('a name over 100 characters is refused in the field', (
      tester,
    ) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/new',
        page: (_) => CreateVoiceRoomView(
          candidates: voicePeople().verifiedContacts(),
          onCreate: (_, _) async => const Result.success(voiceRoomId),
        ),
      );
      final field = find.descendant(
        of: _key('voice-room-name-field'),
        matching: find.byType(EditableText),
      );

      expect(_button(tester, 'voice-room-details-continue').onPressed, isNull);
      await tester.enterText(field, 'x' * 101);
      // Forui shows a field's error a frame after its state changes.
      await tester.pumpAndSettle();
      expect(find.textContaining('This name is too long.'), findsOneWidget);
      expect(_button(tester, 'voice-room-details-continue').onPressed, isNull);

      await tester.enterText(field, 'Standup');
      await tester.pumpAndSettle();
      expect(find.textContaining('This name is too long.'), findsNothing);
      expect(
        _button(tester, 'voice-room-details-continue').onPressed,
        isNotNull,
      );
    });

    testWidgets('only verified contacts are offered, and creating opens the '
        'room', (tester) async {
      final created = <(String, List<String>)>[];
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/new',
        page: (_) => CreateVoiceRoomView(
          candidates: voicePeople().verifiedContacts(),
          onCreate: (name, members) async {
            created.add((name, members));
            return const Result.success(voiceRoomId);
          },
        ),
      );
      await tester.enterText(
        find.descendant(
          of: _key('voice-room-name-field'),
          matching: find.byType(EditableText),
        ),
        'Standup',
      );
      await tester.pump();
      await _tapVisible(tester, _key('voice-room-details-continue'));

      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(find.text('sara'), findsOneWidget);
      expect(find.text('layla'), findsOneWidget);
      expect(find.text('mehdi'), findsNothing, reason: 'not verified');

      await _tapVisible(tester, _key('voice-invite-$voiceSara'));
      await _tapVisible(tester, _key('voice-room-invite-continue'));
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(find.text('People invited: 1'), findsOneWidget);

      await _tapVisible(tester, _key('voice-room-create'));
      expect(created, hasLength(1));
      expect(created.single.$1, 'Standup');
      expect(created.single.$2, [voiceSara]);
      expect(_key('route-info'), findsOneWidget);
    });

    testWidgets('with nobody verified, the invite step routes to '
        'verification', (tester) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/new',
        page: (_) => CreateVoiceRoomView(
          candidates: const [],
          onCreate: (_, _) async => const Result.success(voiceRoomId),
        ),
      );
      await tester.enterText(
        find.descendant(
          of: _key('voice-room-name-field'),
          matching: find.byType(EditableText),
        ),
        'Standup',
      );
      await tester.pump();
      await _tapVisible(tester, _key('voice-room-details-continue'));

      expect(find.text('Nobody to invite yet'), findsOneWidget);
      await _tapVisible(tester, find.text('Verify a contact'));
      expect(_key('route-contacts'), findsOneWidget);
    });

    testWidgets('a create that fails says nothing was sent', (tester) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/new',
        page: (_) => CreateVoiceRoomView(
          candidates: voicePeople().verifiedContacts(),
          onCreate: (_, _) async => const Result.failure(
            ValidationFailure(ValidationFailureKind.invalidInput),
          ),
        ),
      );
      await tester.enterText(
        find.descendant(
          of: _key('voice-room-name-field'),
          matching: find.byType(EditableText),
        ),
        'Standup',
      );
      await tester.pump();
      await _tapVisible(tester, _key('voice-room-details-continue'));
      await _tapVisible(tester, _key('voice-invite-$voiceSara'));
      await _tapVisible(tester, _key('voice-room-invite-continue'));
      await _tapVisible(tester, _key('voice-room-create'));

      expect(
        find.text('The room could not be created. Nothing was sent.'),
        findsOneWidget,
      );
      expect(_key('route-info'), findsNothing);
    });

    testWidgets('a server with no voice offers no room to create', (
      tester,
    ) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/new',
        page: (_) => CreateVoiceRoomView(
          candidates: voicePeople().verifiedContacts(),
          voiceAvailable: false,
          onCreate: (_, _) async => const Result.success(voiceRoomId),
        ),
      );

      expect(_key('voice-room-name-field'), findsNothing);
      expect(find.text('This server does not offer voice'), findsOneWidget);
    });
  });

  group('room info', () {
    Future<List<RoomControlOperation>> pumpInfo(
      WidgetTester tester, {
      RoomState? room,
      bool voiceAvailable = true,
      bool offline = false,
      String? callRoomId,
      VoidCallback? onStartCall,
      Result<RoomState>? answer,
    }) async {
      final changes = <RoomControlOperation>[];
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/$voiceRoomId',
        page: (_) => VoiceRoomInfoView(
          room: room ?? voiceRoom(),
          people: voicePeople(),
          voiceAvailable: voiceAvailable,
          offline: offline,
          callRoomId: callRoomId,
          callDevices: callRoomId == null ? 0 : 2,
          onStartCall: onStartCall ?? () {},
          onMutate: (operation) async {
            changes.add(operation);
            return answer ?? Result.success(room ?? voiceRoom());
          },
        ),
      );
      return changes;
    }

    testWidgets('members are named from contacts with their verification, '
        'and carry no role', (tester) async {
      await pumpInfo(tester);

      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('voice-room-member-$voiceSara'),
          matching: find.text('Verified'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('voice-room-member-$voiceMehdi'),
          matching: find.text('Not verified'),
        ),
        findsOneWidget,
      );
      for (final role in ['Owner', 'Admin', 'Member']) {
        expect(find.text(role), findsNothing);
      }
      expect(find.textContaining('The server stores neither'), findsOneWidget);
    });

    testWidgets('Start a call starts the join and opens the call', (
      tester,
    ) async {
      var started = 0;
      await pumpInfo(tester, onStartCall: () => started += 1);

      await _tapVisible(tester, _key('voice-room-start-call'));

      expect(started, 1);
      expect(_key('route-call'), findsOneWidget);
    });

    testWidgets('a room waiting for its state holds the join, with the '
        'reason', (tester) async {
      await pumpInfo(
        tester,
        room: voiceRoom(lifecycle: RoomLifecycle.stateRecoveryRequired),
      );

      expect(
        find.textContaining('Changes to this room may have been lost'),
        findsOneWidget,
      );
      expect(_button(tester, 'voice-room-start-call').onPressed, isNull);
      expect(find.text("Joining waits for the room's state."), findsOneWidget);
      expect(_key('voice-room-rename'), findsNothing);
      expect(_key('voice-room-invite'), findsNothing);
    });

    testWidgets('conflicting changes pause joining, inviting and renaming', (
      tester,
    ) async {
      await pumpInfo(
        tester,
        room: voiceRoom(lifecycle: RoomLifecycle.forkQuarantined),
      );

      expect(
        find.textContaining('the app will not choose between them'),
        findsOneWidget,
      );
      expect(_button(tester, 'voice-room-start-call').onPressed, isNull);
      expect(_key('voice-room-rename'), findsNothing);
      expect(_key('voice-room-invite'), findsNothing);
      expect(_key('voice-room-leave'), findsNothing);
    });

    testWidgets('a removal names who signed it and offers no call', (
      tester,
    ) async {
      await pumpInfo(
        tester,
        room: voiceRoom(lifecycle: RoomLifecycle.removed, removedBy: voiceSara),
      );

      expect(
        find.textContaining('sara removed you from this room'),
        findsOneWidget,
      );
      expect(find.textContaining('fresh invitation'), findsOneWidget);
      expect(_key('voice-room-start-call'), findsNothing);
      expect(_key('voice-room-leave'), findsNothing);
    });

    testWidgets('the leave dialog says what leaving does, and leaving signs '
        'a removal of oneself', (tester) async {
      final changes = await pumpInfo(tester);

      await _tapVisible(tester, _key('voice-room-leave'));
      expect(find.text('Leave this room?'), findsOneWidget);
      expect(find.textContaining('signed change'), findsOneWidget);
      expect(
        find.textContaining('It does not delete the room'),
        findsOneWidget,
      );
      expect(find.textContaining('fresh invitation'), findsOneWidget);
      await _tapVisible(tester, _key('voice-room-leave-confirm'));

      expect(changes, hasLength(1));
      expect(
        changes.single,
        isA<RemoveRoomMemberOperation>().having(
          (operation) => operation.targetUserId,
          'targetUserId',
          voiceSelf,
        ),
      );
    });

    testWidgets('removing a member states the cost first', (tester) async {
      final changes = await pumpInfo(tester);

      await _tapVisible(tester, _key('voice-room-member-$voiceMehdi'));
      expect(find.text('Not verified'), findsWidgets);
      await _tapVisible(tester, _key('voice-room-remove-member'));
      expect(find.text('Remove mehdi?'), findsOneWidget);
      expect(
        find.textContaining('the only remedy for a removal is a new room'),
        findsOneWidget,
      );
      await _tapVisible(tester, find.text('Remove from room').last);

      expect(
        changes.single,
        isA<RemoveRoomMemberOperation>().having(
          (operation) => operation.targetUserId,
          'targetUserId',
          voiceMehdi,
        ),
      );
    });

    testWidgets('renaming refuses a name over 100 characters', (tester) async {
      final changes = await pumpInfo(tester);

      await _tapVisible(tester, _key('voice-room-rename'));
      final field = find.descendant(
        of: _key('voice-room-rename-field'),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, 'y' * 101);
      await tester.pumpAndSettle();
      expect(find.textContaining('This name is too long.'), findsOneWidget);
      expect(_button(tester, 'voice-room-rename-save').onPressed, isNull);

      await tester.enterText(field, 'Platform Sync');
      await tester.pump();
      await _tapVisible(tester, _key('voice-room-rename-save'));

      expect(
        changes.single,
        isA<RenameRoomOperation>().having(
          (operation) => operation.name,
          'name',
          'Platform Sync',
        ),
      );
    });

    testWidgets('a server with no voice offers no call control', (
      tester,
    ) async {
      await pumpInfo(tester, voiceAvailable: false);

      expect(_key('voice-room-start-call'), findsNothing);
      expect(_key('voice-room-no-voice'), findsOneWidget);
    });

    testWidgets('offline, or in another call, the join is withheld with the '
        'reason', (tester) async {
      await pumpInfo(tester, offline: true);
      expect(_button(tester, 'voice-room-start-call').onPressed, isNull);
      expect(
        find.text('A call cannot start while the server is unreachable.'),
        findsOneWidget,
      );

      await pumpInfo(tester, callRoomId: _otherRoomId);
      expect(_button(tester, 'voice-room-start-call').onPressed, isNull);
      expect(
        find.textContaining('You are in a call in another room.'),
        findsOneWidget,
      );
    });

    testWidgets('in this room\'s call, it returns to the call', (tester) async {
      await pumpInfo(tester, callRoomId: voiceRoomId);

      expect(find.text('Live now · 2'), findsOneWidget);
      await _tapVisible(tester, _key('voice-room-return-to-call'));
      expect(_key('route-call'), findsOneWidget);
    });
  });

  group('the invite picker', () {
    Future<List<RoomControlOperation>> pumpInvite(
      WidgetTester tester, {
      Result<RoomState>? answer,
      List<String> contactsVerified = const [voiceSara, voiceLayla],
    }) async {
      final invites = <RoomControlOperation>[];
      await pumpVoiceRoute(
        tester,
        initialLocation: '/voice-rooms/$voiceRoomId/invite',
        page: (_) => VoiceRoomInviteView(
          room: voiceRoom(),
          people: VoiceRoomPeople(
            currentUserId: voiceSelf,
            people: {
              voiceSara: const VoiceRoomPerson(name: 'sara', verified: true),
              voiceMehdi: const VoiceRoomPerson(name: 'mehdi', verified: false),
              if (contactsVerified.contains(voiceLayla))
                voiceLayla: const VoiceRoomPerson(
                  name: 'layla',
                  verified: true,
                ),
            },
          ),
          onInvite: (operation) async {
            invites.add(operation);
            return answer ?? Result.success(voiceRoom());
          },
        ),
      );
      return invites;
    }

    testWidgets('offers verified contacts who are not members, and invites '
        'the chosen in one signed change', (tester) async {
      final invites = await pumpInvite(tester);

      expect(find.text('layla'), findsOneWidget);
      expect(find.text('sara'), findsNothing, reason: 'already a member');
      expect(find.text('mehdi'), findsNothing, reason: 'not verified');
      expect(
        find.textContaining("the room's whole signed history"),
        findsOneWidget,
      );

      await _tapVisible(tester, _key('voice-invite-$voiceLayla'));
      await _tapVisible(tester, _key('voice-invite-submit'));

      expect(
        invites.single,
        isA<AddRoomMembersOperation>().having(
          (operation) => operation.userIds,
          'userIds',
          [voiceLayla],
        ),
      );
      expect(_key('route-info'), findsOneWidget);
    });

    testWidgets('a history too long for one payload adds nobody, and says '
        'why', (tester) async {
      await pumpInvite(
        tester,
        answer: const Result.failure(
          ValidationFailure(ValidationFailureKind.limitExceeded),
        ),
      );

      await _tapVisible(tester, _key('voice-invite-$voiceLayla'));
      await _tapVisible(tester, _key('voice-invite-submit'));

      expect(find.textContaining('nobody was added'), findsOneWidget);
      expect(_key('route-info'), findsNothing);
    });

    testWidgets('with nobody left to invite, it routes to verification', (
      tester,
    ) async {
      await pumpInvite(tester, contactsVerified: const [voiceSara]);

      expect(find.text('No one left to invite'), findsOneWidget);
      await _tapVisible(tester, find.text('Verify a contact'));
      expect(_key('route-contacts'), findsOneWidget);
    });
  });

  group('Contacts', () {
    testWidgets('New voice room opens the create flow', (tester) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/chats/new',
        overrides: [voiceAvailabilityProvider.overrideWithValue(true)],
        page: (_) => ContactsNewPage(
          ownUserId: voiceSelf,
          contacts: Stream.value(voiceContacts),
        ),
      );

      await _tapVisible(tester, _key('contacts-new-voice-room'));
      expect(_key('route-create'), findsOneWidget);
    });

    testWidgets('on a server with no voice the entry says so and opens '
        'nothing', (tester) async {
      await pumpVoiceRoute(
        tester,
        initialLocation: '/chats/new',
        overrides: [voiceAvailabilityProvider.overrideWithValue(false)],
        page: (_) => ContactsNewPage(
          ownUserId: voiceSelf,
          contacts: Stream.value(voiceContacts),
        ),
      );

      final entry = tester.widget<ListTile>(
        find.descendant(
          of: _key('contacts-new-voice-room'),
          matching: find.byType(ListTile),
        ),
      );
      expect(entry.enabled, isFalse);
      expect(find.text('This server does not offer voice.'), findsOneWidget);
    });
  });
}
