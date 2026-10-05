import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_codec.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// What the room text composer may do with one line.
sealed class VoiceRoomTextCheck {
  const VoiceRoomTextCheck();
}

/// It fits one frame of the largest published bucket.
final class VoiceRoomTextSendable extends VoiceRoomTextCheck {
  const VoiceRoomTextSendable();
}

/// Nothing to read: empty, or nothing but white space.
final class VoiceRoomTextEmpty extends VoiceRoomTextCheck {
  const VoiceRoomTextEmpty();
}

/// Longer than one frame carries. [excessScalars] is how many Unicode scalar
/// values must go from its end before it fits.
final class VoiceRoomTextTooLong extends VoiceRoomTextCheck {
  const VoiceRoomTextTooLong(this.excessScalars);

  final int excessScalars;
}

/// Not text a frame can carry at all: it holds an unpaired surrogate, which
/// has no UTF-8 encoding.
final class VoiceRoomTextUnsendable extends VoiceRoomTextCheck {
  const VoiceRoomTextUnsendable();
}

/// How much room text one `signal` frame carries under the buckets a
/// deployment publishes (`voice-signalling-v1.md`, Sizes, and what fits a
/// bucket).
///
/// The record caps a `room_text` at 2,000 Unicode scalar values and 8,000
/// encoded bytes, which pads into bucket 16384. A deployment whose largest
/// `signal_buckets` entry is smaller cannot carry that: the seal refuses a
/// frame no published bucket holds, and the relay drops an off-bucket frame
/// without a word, so a line the composer let through would look sent and
/// reach nobody. The composer's limit is therefore the smaller of the two -
/// the record's cap, and what the largest published bucket holds under a
/// regular ratchet header, which is the header every frame of a call is
/// sealed under now that no volatile frame starts a session (ADR-077,
/// decided B).
///
/// The frame is measured by the codec itself, with the largest header a line
/// can travel under, rather than by arithmetic on what the codec is assumed
/// to write.
abstract final class VoiceRoomTextBudget {
  /// The version, suite and header-length bytes, the AEAD tag and the real
  /// length (`pairwise-transport-v1.md`).
  static const envelopeOverheadBytes = 24;

  /// A regular Double Ratchet header.
  static const regularHeaderBytes = 58;

  /// The largest `created_ms` a JavaScript-safe clock reaches: nine bytes of
  /// CBOR, the most any wall-clock time costs.
  static const _latestCreatedMs = 0x1fffffffffffff;

  /// The most payload one frame carries under [signalBuckets]: the largest
  /// bucket under a regular header, and never more than the codec takes.
  /// Zero when no bucket is large enough to carry anything.
  static int maximumPayloadBytes(Iterable<int> signalBuckets) {
    var largest = 0;
    for (final bucket in signalBuckets) {
      if (bucket > largest) {
        largest = bucket;
      }
    }
    final carried = largest - envelopeOverheadBytes - regularHeaderBytes;
    if (carried <= 0) {
      return 0;
    }
    return carried < VoiceSignalCodec.maximumPayloadBytes
        ? carried
        : VoiceSignalCodec.maximumPayloadBytes;
  }

  static VoiceRoomTextCheck check(String text, Iterable<int> signalBuckets) {
    if (text.trim().isEmpty) {
      return const VoiceRoomTextEmpty();
    }
    final limit = maximumPayloadBytes(signalBuckets);
    final runes = text.runes.toList(growable: false);
    switch (_fits(runes, runes.length, limit)) {
      case null:
        return const VoiceRoomTextUnsendable();
      case true:
        return const VoiceRoomTextSendable();
      case false:
        break;
    }
    // The longest leading part that fits, by halving: a prefix of a line that
    // fits fits too.
    var fitting = 0;
    var failing = runes.length;
    while (failing - fitting > 1) {
      final middle = (fitting + failing) ~/ 2;
      if (_fits(runes, middle, limit) ?? false) {
        fitting = middle;
      } else {
        failing = middle;
      }
    }
    return VoiceRoomTextTooLong(runes.length - fitting);
  }

  /// Whether the first [length] scalar values of [runes] fit, or null when
  /// they are not text a frame can carry.
  static bool? _fits(List<int> runes, int length, int limit) {
    if (length > VoiceSignalLimits.maximumRoomTextScalars) {
      return false;
    }
    final text = String.fromCharCodes(runes, 0, length);
    if (utf8.encode(text).length > VoiceSignalLimits.maximumRoomTextBytes) {
      return false;
    }
    final VoiceRoomText body;
    try {
      body = VoiceRoomText(text);
    } on FormatException {
      return null;
    }
    final encoded = VoiceSignalCodec.encode(
      VoiceSignalMessage(
        header: VoiceSignalHeader(
          roomId: Uint8List(VoiceSignalLimits.roomIdBytes),
          joinId: Uint8List(VoiceSignalLimits.joinIdBytes),
          senderUserId: Uint8List(VoiceSignalLimits.uuidBytes),
          senderDeviceId: Uint8List(VoiceSignalLimits.uuidBytes),
          counter: VoiceSignalLimits.maximumCounter,
          createdMs: _latestCreatedMs,
        ),
        body: body,
      ),
    );
    return switch (encoded) {
      Success(:final value) => value.length <= limit,
      FailureResult() => false,
    };
  }
}
