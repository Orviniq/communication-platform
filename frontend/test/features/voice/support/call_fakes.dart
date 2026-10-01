import 'dart:async';
import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/application/ports/relay_credential_ports.dart';
import 'package:communication_platform/features/voice/application/ports/room_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_call_ports.dart';
import 'package:communication_platform/features/voice/application/ports/voice_signalling_ports.dart';
import 'package:communication_platform/features/voice/application/relay_credential_service.dart';
import 'package:communication_platform/features/voice/application/voice_call_engine.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/room_model.dart';
import 'package:communication_platform/features/voice/domain/voice_call_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

import 'peer_fakes.dart';
import 'relay_fakes.dart';
import 'room_fakes.dart';

/// The room every simulated call is in.
const callRoomId =
    'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';

/// The account of device [index]. One device per account unless a test says
/// otherwise.
String callUserId(int index) =>
    '${(0xa0000000 + index).toRadixString(16)}-0000-4000-8000-'
    '${(0xa000 + index).toRadixString(16).padLeft(12, '0')}';

/// The id of device [index]. Ids sort in index order, so a test chooses which
/// device the ceiling keeps by choosing its index.
String callDeviceId(int index) =>
    '${(0xd0000000 + index).toRadixString(16)}-0000-4000-8000-'
    '${(0xd000 + index).toRadixString(16).padLeft(12, '0')}';

/// One clock for every device of a simulated call. A wait completes only when
/// [elapse] moves the clock past it, so a test spends no real time and every
/// retry happens exactly when the schedule says.
final class CallClock implements TimeSource, VoiceSignalTimerPort {
  CallClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 10, 1, 12);

  DateTime _now;
  final _waits = <_CallWait>[];
  var _issued = 0;

  @override
  DateTime now() => _now;

  @override
  Future<void> wait(Duration duration) {
    final wait = _CallWait(
      _now.add(duration.isNegative ? Duration.zero : duration),
      _issued++,
    );
    _waits.add(wait);
    return wait.completer.future;
  }

  /// Moves the clock on by [duration], completing each wait as its moment
  /// comes, the earliest first, and letting what each one starts run before
  /// the next.
  Future<void> elapse(Duration duration) async {
    final end = _now.add(duration);
    await settleCall();
    while (true) {
      _waits.sort((left, right) {
        final byTime = left.at.compareTo(right.at);
        return byTime != 0 ? byTime : left.order.compareTo(right.order);
      });
      if (_waits.isEmpty || _waits.first.at.isAfter(end)) {
        break;
      }
      final next = _waits.removeAt(0);
      if (next.at.isAfter(_now)) {
        _now = next.at;
      }
      next.completer.complete();
      await settleCall();
    }
    _now = end;
    await settleCall();
  }
}

final class _CallWait {
  _CallWait(this.at, this.order);

  final DateTime at;
  final int order;
  final completer = Completer<void>();
}

/// Lets every pending microtask and event of every device run.
Future<void> settleCall() async {
  for (var turn = 0; turn < 40; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A room's roster, as each member's devices hold it: one signed chain that
/// every view reads, with this account's own lifecycle laid over it.
final class CallRoom {
  CallRoom({required Iterable<String> members, this.roomId = callRoomId})
    : _active = {for (final member in members) member.toLowerCase()};

  final String roomId;
  final Set<String> _active;
  final _removedBy = <String, String>{};
  final _changes = StreamController<void>.broadcast();
  var revision = 1;

  /// Laid over every member's view: a room waiting for its state, or forked.
  RoomLifecycle? lifecycleForAll;

  Set<String> get activeMembers => Set.unmodifiable(_active);

  /// The room as [userId]'s devices hold it, or null for an account that was
  /// never in it.
  RoomState? stateFor(String userId) {
    final local = userId.toLowerCase();
    if (!_active.contains(local) && !_removedBy.containsKey(local)) {
      return null;
    }
    final lifecycle =
        lifecycleForAll ??
        (_active.contains(local)
            ? RoomLifecycle.active
            : RoomLifecycle.removed);
    final quarantined =
        lifecycle == RoomLifecycle.forkQuarantined ||
        lifecycle == RoomLifecycle.controlQuarantined;
    return RoomState(
      roomId: roomId,
      name: 'Standup',
      members: [
        for (final member in _active) RoomMember(userId: member),
        for (final member in _removedBy.keys)
          RoomMember(userId: member, membership: RoomMembershipState.removed),
      ],
      controlRevision: revision,
      controlStateHash: revision.toRadixString(16).padLeft(64, '0'),
      lifecycle: lifecycle,
      quarantineReason: quarantined
          ? RoomQuarantineReason.siblingControl
          : null,
      removedByUserId: lifecycle == RoomLifecycle.removed
          ? _removedBy[local]
          : null,
    );
  }

  /// Commits a signed removal of [userId] by [by], as every member's device
  /// would after applying it.
  void remove(String userId, {required String by}) {
    _active.remove(userId.toLowerCase());
    _removedBy[userId.toLowerCase()] = by.toLowerCase();
    revision += 1;
    _changes.add(null);
  }

  void setLifecycleForAll(RoomLifecycle? lifecycle) {
    lifecycleForAll = lifecycle;
    revision += 1;
    _changes.add(null);
  }

  RoomStateReadPort viewFor(String userId) => _CallRoomView(this, userId);
}

final class _CallRoomView implements RoomStateReadPort {
  _CallRoomView(this.room, this.userId);

  final CallRoom room;
  final String userId;
  var reads = 0;

  RoomState? _state(String roomId) =>
      roomId == room.roomId ? room.stateFor(userId) : null;

  @override
  Future<Result<RoomState?>> readRoom(String roomId) async {
    reads += 1;
    return Result.success(_state(roomId));
  }

  @override
  Stream<RoomState?> watchRoom(String roomId) =>
      Stream<RoomState?>.multi((controller) {
        controller.add(_state(roomId));
        final subscription = room._changes.stream.listen(
          (_) => controller.add(_state(roomId)),
        );
        controller.onCancel = subscription.cancel;
      });

  @override
  Stream<List<RoomState>> watchRooms() =>
      Stream<List<RoomState>>.multi((controller) {
        List<RoomState> rooms() => [?room.stateFor(userId)];
        controller.add(rooms());
        final subscription = room._changes.stream.listen(
          (_) => controller.add(rooms()),
        );
        controller.onCancel = subscription.cancel;
      });
}

/// One frame the relay carried, or would have.
final class CallFrame {
  const CallFrame({
    required this.from,
    required this.to,
    required this.message,
    required this.at,
    required this.dropped,
  });

  final String from;
  final String to;
  final VoiceSignalMessage message;
  final DateTime at;

  /// Nobody was listening for it, so the relay dropped it.
  final bool dropped;

  VoiceSignalKind get kind => message.kind;
  int get counter => message.header.counter;
}

/// The relay between the devices of a simulated call, with the transport's
/// own rules on each end: a target list must be a set of other devices, and
/// one join seals at most 32 frames to one device. A frame for a device that
/// is not listening is dropped, as the relay drops one for a device that is
/// not connected at that instant.
final class CallSignalNetwork {
  CallSignalNetwork(this.clock);

  final CallClock clock;
  final _ends = <String, CallSignalling>{};
  final frames = <CallFrame>[];

  /// Sends the transport would have refused outright.
  final invalidSends = <String>[];

  /// Devices that hear nothing: every frame to them is dropped.
  final deaf = <String>{};

  /// Directions that carry nothing, as `(from, to)` device ids.
  final cut = <(String, String)>{};

  /// Frames dropped once each: the first frame of that kind on that
  /// direction is lost, and the next goes through.
  final dropOnce = <(VoiceSignalKind, String, String)>{};
  final _budgets = <String, int>{};

  CallSignalling attach(String userId, String deviceId) =>
      _ends[deviceId] = CallSignalling._(this, userId, deviceId);

  /// Hands [toDeviceId] a frame as though the pairwise session had
  /// authenticated it as [fromUserId]'s device [fromDeviceId].
  void inject({
    required String toDeviceId,
    required String fromUserId,
    required String fromDeviceId,
    required VoiceSignalMessage message,
  }) => _ends[toDeviceId]!._deliver(
    ReceivedVoiceSignal(
      senderUserId: fromUserId,
      senderDeviceId: fromDeviceId,
      message: message,
    ),
  );

  /// Hands [toDeviceId] what the transport reports for a frame whose major
  /// version this build does not speak.
  void injectUnsupported({
    required String toDeviceId,
    required String fromUserId,
    required String fromDeviceId,
  }) => _ends[toDeviceId]!._deliver(
    UnsupportedVoiceSignal(
      senderUserId: fromUserId,
      senderDeviceId: fromDeviceId,
      version: 2,
    ),
  );

  List<CallFrame> framesOf(VoiceSignalKind kind, {String? from, String? to}) =>
      [
        for (final frame in frames)
          if (frame.kind == kind &&
              (from == null || frame.from == from) &&
              (to == null || frame.to == to))
            frame,
      ];

  VoiceSignalRefusal? _spend(Uint8List joinId, String to) {
    final key = '${protocolBytesToHex(joinId)}>$to';
    final spent = _budgets[key] ?? 0;
    if (spent >= 32) {
      return VoiceSignalRefusal.budgetExhausted;
    }
    _budgets[key] = spent + 1;
    return null;
  }

  void _carry(CallSignalling from, String to, VoiceSignalMessage message) {
    final end = _ends[to];
    final dropped =
        end == null ||
        deaf.contains(to) ||
        cut.contains((from.deviceId, to)) ||
        dropOnce.remove((message.kind, from.deviceId, to));
    frames.add(
      CallFrame(
        from: from.deviceId,
        to: to,
        message: message,
        at: clock.now(),
        dropped: dropped,
      ),
    );
    if (!dropped) {
      end._deliver(
        ReceivedVoiceSignal(
          senderUserId: from.userId,
          senderDeviceId: from.deviceId,
          message: message,
        ),
      );
    }
  }
}

/// One device's end of [CallSignalNetwork].
final class CallSignalling implements VoiceSignallingPort {
  CallSignalling._(this.network, this.userId, this.deviceId);

  final CallSignalNetwork network;
  final String userId;
  final String deviceId;
  final _inbound = StreamController<InboundVoiceSignal>.broadcast();
  final forgotten = <String>[];

  /// Targets the transport refuses, and why.
  final refusals = <String, VoiceSignalRefusal>{};

  /// A send of one of these kinds waits until its completer completes.
  final holds = <VoiceSignalKind, Completer<void>>{};

  @override
  Stream<InboundVoiceSignal> get inbound => _inbound.stream;

  @override
  void forgetJoin(Uint8List joinId) =>
      forgotten.add(protocolBytesToHex(joinId));

  @override
  Future<Result<List<VoiceSignalDelivery>>> send({
    required Uint8List roomId,
    required Uint8List joinId,
    required int counter,
    required VoiceSignalBody body,
    required List<VoiceSignalTarget> targets,
  }) async {
    final hold = holds[body.kind];
    if (hold != null) {
      await hold.future;
    }
    final ids = [for (final target in targets) target.deviceId.toLowerCase()];
    if (ids.isEmpty ||
        ids.toSet().length != ids.length ||
        ids.contains(deviceId)) {
      network.invalidSends.add('${body.kind.name} from $deviceId');
      return const Result.failure(
        ValidationFailure(ValidationFailureKind.invalidInput),
      );
    }
    final message = VoiceSignalMessage(
      header: VoiceSignalHeader(
        roomId: roomId,
        joinId: joinId,
        senderUserId: protocolUuidBytes(userId),
        senderDeviceId: protocolUuidBytes(deviceId),
        counter: counter,
        createdMs: network.clock.now().millisecondsSinceEpoch,
      ),
      body: body,
    );
    final deliveries = <VoiceSignalDelivery>[];
    for (final target in targets) {
      final refusal =
          refusals[target.deviceId] ?? network._spend(joinId, target.deviceId);
      if (refusal != null) {
        deliveries.add(VoiceSignalNotSent(target, refusal));
        continue;
      }
      network._carry(this, target.deviceId, message);
      deliveries.add(VoiceSignalSent(target));
    }
    return Result.success(deliveries);
  }

  void _deliver(InboundVoiceSignal signal) {
    if (!_inbound.isClosed) {
      _inbound.add(signal);
    }
  }
}

/// `POST /api/v1/me/relay`: mints a six-hour credential each time it is
/// asked, unless a test sets [answer].
final class MintingRelayPort implements RelayCredentialPort {
  MintingRelayPort(this.clock, {this.framesSent});

  final TimeSource clock;

  /// How many frames the relay had carried, read at each mint.
  final int Function()? framesSent;
  final mints = <DateTime>[];
  final framesAtMint = <int>[];
  Result<RelayCredential>? answer;

  @override
  Future<Result<RelayCredential>> mint() async {
    mints.add(clock.now());
    framesAtMint.add(framesSent?.call() ?? 0);
    final custom = answer;
    if (custom != null) {
      return custom;
    }
    return Result.success(
      RelayCredential(
        urls: relayUrls,
        username: relayUsername,
        credential: '$relayPassword${mints.length}',
        lifetime: const Duration(hours: 6),
        expiresAt: clock.now().add(const Duration(hours: 6)),
      ),
    );
  }
}

final class RecordingCallSessions implements VoiceCallSessionsPort {
  RecordingCallSessions({this.framesSent});

  /// How many frames the relay had carried, read at each preparation.
  final int Function()? framesSent;
  final prepared = <String>[];
  final framesAtPreparation = <int>[];

  @override
  Future<Result<void>> prepareSessionsForCall(String roomId) async {
    prepared.add(roomId);
    framesAtPreparation.add(framesSent?.call() ?? 0);
    return const Result.success(null);
  }
}

/// Every wait at its nominal length.
final class FixedJitter implements VoiceRetryJitterPort {
  const FixedJitter([this.value = 0.5]);

  final double value;

  @override
  double next() => value;
}

/// One device of a simulated call, with everything its engine was built on.
final class CallDevice {
  CallDevice._({
    required this.index,
    required this.userId,
    required this.deviceId,
    required this.signalling,
    required this.media,
    required this.audio,
    required this.relay,
    required this.sessions,
    required this.engine,
  }) {
    engine.states.listen(states.add);
  }

  final int index;
  final String userId;
  final String deviceId;
  final CallSignalling signalling;
  final FakePeerMediaPort media;
  final FakeLocalAudioPort audio;
  final MintingRelayPort relay;
  final RecordingCallSessions sessions;
  final VoiceCallEngine engine;
  final states = <VoiceCallState>[];

  VoiceCallState get state => engine.state;

  VoiceCallParticipant? participant(CallDevice other) {
    for (final participant in state.participants) {
      if (participant.deviceId == other.deviceId) {
        return participant;
      }
    }
    return null;
  }

  VoiceParticipantStatus? statusOf(CallDevice other) =>
      participant(other)?.status;

  /// The platform connections this device opened that are still open.
  List<FakePeerMedia> get openConnections => [
    for (final connection in media.opened)
      if (!connection.closed) connection,
  ];
}

/// Devices in one room, each with its own engine, joined by one relay and
/// one clock.
final class CallMesh {
  CallMesh({int accounts = 3, Iterable<int>? members})
    : clock = CallClock(),
      room = CallRoom(
        members: [
          for (final index in members ?? List.generate(accounts, (i) => i))
            callUserId(index),
        ],
      ) {
    network = CallSignalNetwork(clock);
    liveDevices = FakeRoomLiveDevices({
      for (var index = 0; index < accounts; index += 1)
        callUserId(index): [callDeviceId(index)],
    });
  }

  final CallClock clock;
  final CallRoom room;
  late final CallSignalNetwork network;
  late final FakeRoomLiveDevices liveDevices;
  final _devices = <int, CallDevice>{};

  /// Device [index], built on first use.
  CallDevice device(int index) => _devices[index] ??= _build(index);

  CallDevice _build(int index) {
    final userId = callUserId(index);
    final deviceId = callDeviceId(index);
    final signalling = network.attach(userId, deviceId);
    final media = FakePeerMediaPort('d$index-');
    final audio = FakeLocalAudioPort();
    int sentBy() => [
      for (final frame in network.frames)
        if (frame.from == deviceId) frame,
    ].length;
    final relay = MintingRelayPort(clock, framesSent: sentBy);
    final sessions = RecordingCallSessions(framesSent: sentBy);
    final engine = VoiceCallEngine(
      currentUserId: userId,
      currentDeviceId: deviceId,
      rooms: room.viewFor(userId),
      liveDevices: liveDevices,
      sessions: sessions,
      credentials: RelayCredentialService(
        remote: relay,
        deployment: const FixedVoiceDeployment(voiceConfigured: true),
        clock: clock,
      ),
      signalling: signalling,
      media: media,
      localAudio: audio,
      identity: FakeRoomIdentity(index + 1),
      clock: clock,
      timer: clock,
      jitter: const FixedJitter(),
    )..start();
    return CallDevice._(
      index: index,
      userId: userId,
      deviceId: deviceId,
      signalling: signalling,
      media: media,
      audio: audio,
      relay: relay,
      sessions: sessions,
      engine: engine,
    );
  }

  /// Joins [device] and lets the first answer window pass, so that its join
  /// has gone out when this returns.
  Future<VoiceJoinOutcome> join(CallDevice device) async {
    final joining = device.engine.join(room.roomId);
    await clock.elapse(const Duration(seconds: 3));
    return joining;
  }

  /// Joins each device in turn and lets the call settle after each.
  Future<void> joinAll(Iterable<CallDevice> devices) async {
    for (final device in devices) {
      await join(device);
      await clock.elapse(const Duration(seconds: 25));
    }
  }

  Future<void> dispose() async {
    for (final device in _devices.values) {
      await device.engine.dispose();
    }
  }
}
