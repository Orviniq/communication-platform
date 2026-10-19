import 'dart:typed_data';

/// The bounds ADR-098 D2 sets on a `CPPSV001` body.
abstract final class PresenceSignalLimits {
  static const uuidBytes = 16;
  static const instanceIdBytes = 16;
  static const conversationIdBytes = 32;

  /// A `counter`: monotonic within one `instance_id`, from 1.
  static const maximumCounter = 0xffffffff;

  /// What a `watch` may ask for, and what every sender asks for.
  static const maximumLeaseMs = 60000;
  static const watchLeaseMs = 40000;

  /// The longest an active `typing` frame may last.
  static const maximumTypingTtlMs = 15000;
}

/// The four kinds, by the value the frame carries after its version byte.
enum PresenceSignalKind {
  watch(1),
  here(2),
  typing(3),
  gone(4);

  const PresenceSignalKind(this.wireValue);

  final int wireValue;

  static PresenceSignalKind? fromWireValue(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// One presence message: the header every kind carries, and its body.
final class PresenceSignalMessage {
  const PresenceSignalMessage({required this.header, required this.body});

  final PresenceSignalHeader header;
  final PresenceSignalBody body;

  PresenceSignalKind get kind => body.kind;

  @override
  String toString() => 'PresenceSignalMessage(${kind.name}, <redacted>)';
}

/// Keys 0 to 3 of every body.
///
/// [senderUserId] and [senderDeviceId] are what the sender says about itself.
/// A receiver accepts them only when they equal the device the pairwise
/// session authenticated; they never name the sender on their own.
final class PresenceSignalHeader {
  PresenceSignalHeader({
    required Uint8List senderUserId,
    required Uint8List senderDeviceId,
    required Uint8List instanceId,
    required this.counter,
  }) : senderUserId = _exact(senderUserId, PresenceSignalLimits.uuidBytes),
       senderDeviceId = _exact(senderDeviceId, PresenceSignalLimits.uuidBytes),
       instanceId = _exact(instanceId, PresenceSignalLimits.instanceIdBytes) {
    if (counter < 1 || counter > PresenceSignalLimits.maximumCounter) {
      throw const FormatException('invalid presence signal counter');
    }
  }

  final Uint8List senderUserId;
  final Uint8List senderDeviceId;

  /// Random bytes the sender minted when its presence channel started in a
  /// process. A new one means the sender's app restarted.
  final Uint8List instanceId;

  /// Monotonic within [instanceId].
  final int counter;
}

sealed class PresenceSignalBody {
  const PresenceSignalBody();

  PresenceSignalKind get kind;
}

/// "I have this conversation open": the status query and the typing interest
/// in one frame (ADR-098 D4).
final class PresenceWatch extends PresenceSignalBody {
  PresenceWatch({required Uint8List conversationId, required this.leaseMs})
    : conversationId = _exact(
        conversationId,
        PresenceSignalLimits.conversationIdBytes,
      ) {
    if (leaseMs < 1 || leaseMs > PresenceSignalLimits.maximumLeaseMs) {
      throw const FormatException('invalid presence lease');
    }
  }

  final Uint8List conversationId;
  final int leaseMs;

  @override
  PresenceSignalKind get kind => PresenceSignalKind.watch;
}

/// The answer to one watch, and whether this device is typing there.
final class PresenceHere extends PresenceSignalBody {
  PresenceHere({required Uint8List conversationId, required this.typing})
    : conversationId = _exact(
        conversationId,
        PresenceSignalLimits.conversationIdBytes,
      );

  final Uint8List conversationId;
  final bool typing;

  @override
  PresenceSignalKind get kind => PresenceSignalKind.here;
}

/// Typing started, went on, or stopped. [ttlMs] is present exactly when
/// [active] is.
final class PresenceTyping extends PresenceSignalBody {
  PresenceTyping({
    required Uint8List conversationId,
    required this.active,
    this.ttlMs,
  }) : conversationId = _exact(
         conversationId,
         PresenceSignalLimits.conversationIdBytes,
       ) {
    final ttl = ttlMs;
    if (active
        ? ttl == null ||
              ttl < 1 ||
              ttl > PresenceSignalLimits.maximumTypingTtlMs
        : ttl != null) {
      throw const FormatException('invalid typing ttl');
    }
  }

  final Uint8List conversationId;
  final bool active;
  final int? ttlMs;

  @override
  PresenceSignalKind get kind => PresenceSignalKind.typing;
}

/// Why a device said goodbye.
enum PresenceGoneReason {
  leftForeground(1),
  statusTurnedOff(2);

  const PresenceGoneReason(this.wireValue);

  final int wireValue;

  static PresenceGoneReason? fromWireValue(int value) {
    for (final reason in values) {
      if (reason.wireValue == value) {
        return reason;
      }
    }
    return null;
  }
}

/// This device is leaving: end its online state and its leases at once.
final class PresenceGone extends PresenceSignalBody {
  const PresenceGone(this.reason);

  final PresenceGoneReason reason;

  @override
  PresenceSignalKind get kind => PresenceSignalKind.gone;
}

Uint8List _exact(Uint8List value, int length) {
  if (value.length != length) {
    throw const FormatException('invalid presence signal field length');
  }
  return Uint8List.fromList(value);
}
