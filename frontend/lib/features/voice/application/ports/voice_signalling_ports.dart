import 'dart:typed_data';

import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// One device a signalling message goes to.
final class VoiceSignalTarget {
  const VoiceSignalTarget({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

/// Why a target got no frame. Each is something the call can say about that
/// one peer while the rest of the call carries on.
enum VoiceSignalRefusal {
  /// Its account's authenticated live device list does not name it.
  notLive,

  /// Its identity is blocked: a changed safety number, or a device-log fork.
  identityBlocked,

  /// Its account's device list could not be authenticated just now.
  unverified,

  /// No secure session exists with it yet. A session is never started by a
  /// signal frame; it starts on the durable path.
  noSession,

  /// Its session is waiting on a repair.
  sessionUnderRepair,

  /// This join has already sealed 32 frames to it.
  budgetExhausted,

  /// The sealed frame is not one of the published signal buckets.
  offBucket,

  /// Sealing, or committing the advanced state, failed. Nothing was sent.
  sealFailed,

  /// The socket did not take the frame: it is not connected. The frame was
  /// sealed and committed, and is gone; a retry seals again.
  socketUnavailable,
}

/// What one target of a send came to.
sealed class VoiceSignalDelivery {
  const VoiceSignalDelivery(this.target);

  final VoiceSignalTarget target;
}

/// Sealed, committed and handed to the socket. Nothing ever reports whether
/// it arrived: a target that is not connected at that instant gets nothing.
final class VoiceSignalSent extends VoiceSignalDelivery {
  const VoiceSignalSent(super.target);
}

final class VoiceSignalNotSent extends VoiceSignalDelivery {
  const VoiceSignalNotSent(super.target, this.reason);

  final VoiceSignalRefusal reason;
}

/// A frame that arrived, opened and was accepted.
///
/// [senderUserId] and [senderDeviceId] are the device the pairwise session
/// authenticated, and a message whose header names any other device is never
/// delivered.
sealed class InboundVoiceSignal {
  const InboundVoiceSignal({
    required this.senderUserId,
    required this.senderDeviceId,
  });

  final String senderUserId;
  final String senderDeviceId;
}

final class ReceivedVoiceSignal extends InboundVoiceSignal {
  const ReceivedVoiceSignal({
    required super.senderUserId,
    required super.senderDeviceId,
    required this.message,
  });

  final VoiceSignalMessage message;

  @override
  String toString() => 'ReceivedVoiceSignal(${message.kind.name}, <redacted>)';
}

/// A peer that speaks a major version this build does not. Its frame is
/// dropped; this says who sent it, so the call can say that peer needs a
/// newer build rather than that it is quiet.
final class UnsupportedVoiceSignal extends InboundVoiceSignal {
  const UnsupportedVoiceSignal({
    required super.senderUserId,
    required super.senderDeviceId,
    required this.version,
  });

  final int version;

  @override
  String toString() => 'UnsupportedVoiceSignal(version: $version)';
}

/// The call's signalling channel: `CPVSV001` over volatile `signal` frames,
/// each sealed to the pairwise session of the device it goes to.
abstract interface class VoiceSignallingPort implements Port {
  /// Every accepted message, in the order its frame was opened. Nothing is
  /// replayed to a late listener; a frame nobody hears is gone, as it would
  /// be had the relay dropped it.
  Stream<InboundVoiceSignal> get inbound;

  /// Seals one message for each of [targets], commits each advanced session,
  /// and hands one frame for each to the socket, paced.
  ///
  /// This device's own ids and the send time complete the header. [counter]
  /// is the caller's: a retry carries the counter of the message it retries,
  /// so that the receiver can drop the duplicate, and is sealed again on the
  /// next message number rather than resent.
  ///
  /// A failure is a message that cannot be sent to anybody: one that does not
  /// fit a signal frame, or a target list that is not a set of other devices.
  /// Everything else is a [VoiceSignalDelivery] for each target, in order.
  Future<Result<List<VoiceSignalDelivery>>> send({
    required Uint8List roomId,
    required Uint8List joinId,
    required int counter,
    required VoiceSignalBody body,
    required List<VoiceSignalTarget> targets,
  });

  /// Forgets the frame budget of this device's join [joinId], which the call
  /// runs when it leaves.
  void forgetJoin(Uint8List joinId);
}

/// The `/ws` socket, as far as signalling needs it.
abstract interface class VoiceSignalSocketPort implements Port {
  /// The blob of every `signal` frame the socket delivered, as it arrived.
  Stream<String> get inboundBlobs;

  /// Sends one `signal` frame. A failure means the socket did not take it,
  /// and nothing was sent.
  Future<Result<void>> sendSignal({
    required String toDeviceId,
    required String blob,
  });
}

/// What sealing came to for one target.
sealed class VoiceSealOutcome {
  const VoiceSealOutcome(this.target);

  final VoiceSignalTarget target;
}

final class VoiceSealed extends VoiceSealOutcome {
  VoiceSealed(super.target, Uint8List frame)
    : frame = Uint8List.fromList(frame);

  /// The exact `EnvelopeV1`, its session state already committed.
  final Uint8List frame;

  @override
  String toString() => 'VoiceSealed(<redacted>)';
}

final class VoiceSealRefused extends VoiceSealOutcome {
  const VoiceSealRefused(super.target, this.reason);

  final VoiceSignalRefusal reason;
}

/// Seals one payload to each target's pairwise session, and commits every
/// advanced state before any frame is returned.
abstract interface class VoiceSignalSealPort implements Port {
  /// One outcome for each of [targets], in order. A failure means nothing was
  /// committed and no frame exists.
  Future<Result<List<VoiceSealOutcome>>> seal({
    required Uint8List payload,
    required List<VoiceSignalTarget> targets,
    required Set<int> allowedLengths,
  });
}

/// Opens one frame under its pairwise session, writing nothing.
abstract interface class VoiceSignalOpenPort implements Port {
  Future<Result<VoiceSignalOpening>> open(Uint8List frame);
}

/// A frame opened and not yet committed.
abstract interface class VoiceSignalOpening {
  /// The device the pairwise session authenticated.
  String get senderUserId;
  String get senderDeviceId;

  Uint8List get payload;

  /// Writes what opening the frame advanced.
  Future<Result<void>> commit();
}

/// The deployment's published `signal_buckets`, read when asked.
abstract interface class VoiceSignalBucketsPort implements Port {
  Set<int> get signalBuckets;
}

/// Waits, so that a test can move time instead of spending it.
abstract interface class VoiceSignalTimerPort implements Port {
  Future<void> wait(Duration duration);
}
