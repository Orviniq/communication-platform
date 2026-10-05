import 'dart:typed_data';

import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// Whether this device is the polite peer of the perfect-negotiation pattern
/// toward [remoteDeviceId]: of two devices, the one whose id string sorts
/// lower is polite (`backend/CLIENT_CONTRACT.md` §N rule 3).
///
/// Both ends compute it from the two ids alone, so there is nothing to agree
/// on and no server to ask. The ids are compared in lowercase, so that an id
/// one side spells in capitals still sorts where the other side sorts it; for
/// a canonical UUID string that order is the order of its bytes.
bool isPoliteVoicePeer({
  required String localDeviceId,
  required String remoteDeviceId,
}) {
  final local = localDeviceId.toLowerCase();
  final remote = remoteDeviceId.toLowerCase();
  if (local == remote) {
    throw ArgumentError('A device is never its own peer.');
  }
  return local.compareTo(remote) < 0;
}

/// The far end of one connection: one device, in one of its joins.
///
/// A connection is keyed on the device and its `join_id`, because a device
/// that leaves and joins again is a new incarnation with a new join id, and
/// its old connection is not its new one (`voice-signalling-v1.md`, The common
/// body header).
final class VoicePeerAddress {
  VoicePeerAddress({
    required this.userId,
    required this.deviceId,
    required Uint8List joinId,
  }) : joinId = Uint8List.fromList(joinId) {
    // Both are UUIDs on the wire; this throws a FormatException otherwise.
    protocolUuidBytes(userId);
    protocolUuidBytes(deviceId);
    if (this.joinId.length != VoiceSignalLimits.joinIdBytes) {
      throw const FormatException('invalid join id length');
    }
  }

  final String userId;
  final String deviceId;
  final Uint8List joinId;

  @override
  String toString() => 'VoicePeerAddress(<redacted>)';
}

enum VoiceDescriptionType { offer, answer }

/// One SDP offer or answer.
///
/// The text names the endpoint's DTLS fingerprint and ICE credentials, and a
/// candidate inside one names an address, so it has no string form and is
/// never logged. Its only trust is the pairwise session it arrived in: the
/// fingerprint it carries is what authenticates the DTLS handshake end to end
/// (§N rule 6).
final class VoiceSessionDescription {
  const VoiceSessionDescription({required this.type, required this.sdp});

  final VoiceDescriptionType type;
  final String sdp;

  /// Whether it describes what §N rule 1 allows a connection: one media
  /// section, and that section audio.
  ///
  /// A video section or an application section is how a video track or a
  /// data channel would come into being on the receiving side, so a
  /// description that carries one is never applied, and neither is a second
  /// audio section.
  bool get isAudioOnly {
    var sections = 0;
    var audio = 0;
    for (final line in sdp.split('\n')) {
      if (line.startsWith('m=')) {
        sections += 1;
        if (line.startsWith('m=audio ')) {
          audio += 1;
        }
      }
    }
    return sections == 1 && audio == 1;
  }

  /// The ICE user fragment this description names: the credentials of one ICE
  /// generation. BUNDLE puts the one section on one transport, so there is
  /// one.
  String? get iceUfrag => _descriptionUfrag.firstMatch(sdp)?.group(1);

  @override
  String toString() => 'VoiceSessionDescription(${type.name}, <redacted>)';
}

/// The ICE user fragment a candidate line names in its `ufrag` extension:
/// which ICE generation gathered it.
///
/// libwebrtc writes the extension on every candidate it surfaces
/// (`SdpSerializeCandidate`), so a candidate of an abandoned generation — one
/// a rollback or a restart left behind — can be told from a current one
/// without trusting the order the platform's events arrive in.
String? iceUfragOfCandidate(String candidate) =>
    _candidateUfrag.firstMatch(candidate)?.group(1);

final RegExp _descriptionUfrag = RegExp(
  r'^a=ice-ufrag:([^\r\n]+)',
  multiLine: true,
);

final RegExp _candidateUfrag = RegExp(r'(?:^| )ufrag (\S+)');
