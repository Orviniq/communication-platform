import 'package:communication_platform/core/application/ports/port.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/voice/domain/relay_credential_model.dart';
import 'package:communication_platform/features/voice/domain/voice_peer_model.dart';
import 'package:communication_platform/features/voice/domain/voice_signal_model.dart';

/// The platform's WebRTC, as far as one call needs it: one
/// `RTCPeerConnection` for each device pair (`backend/CLIENT_CONTRACT.md` §N
/// rule 1).
///
/// There is no way to ask it for a video track, a transceiver of any other
/// kind or a data channel, because this version has none.
abstract interface class VoicePeerMediaPort implements Port {
  /// One platform connection, configured with [configuration] and nothing
  /// else, and carrying [audio] as its one track.
  ///
  /// [configuration] can only have been built from a relay credential, so the
  /// connection has the relay's `turn:` servers, the `relay` transport policy
  /// and no STUN server (§N rule 2).
  Future<Result<VoicePeerMedia>> open({
    required RelayIceConfiguration configuration,
    required VoiceLocalAudio audio,
  });
}

/// One platform connection.
///
/// Each call is one step of an offer and answer, and a refusal is a failure,
/// never a throw. A failure carries no platform text: libwebrtc quotes the
/// description line it could not parse, and that is an SDP in an error.
abstract interface class VoicePeerMedia {
  /// What the platform reports: the candidates it gathers and the state of
  /// the connection. Never replayed to a late listener.
  Stream<VoicePeerMediaEvent> get events;

  Future<Result<VoiceSessionDescription>> createOffer();

  /// Answers the remote offer applied last.
  Future<Result<VoiceSessionDescription>> createAnswer();

  Future<Result<void>> setLocalDescription(VoiceSessionDescription description);

  /// Discards the local offer, from `have-local-offer` back to `stable`.
  ///
  /// Explicit, because the platform does no implicit rollback: libwebrtc
  /// refuses a remote offer while a local one is pending unless
  /// `enableImplicitRollback` is set, and `flutter_webrtc` has no way to set
  /// it (`PeerConnection.RTCConfiguration`, libwebrtc 150.7871.01).
  Future<Result<void>> rollbackLocalOffer();

  Future<Result<void>> setRemoteDescription(
    VoiceSessionDescription description,
  );

  Future<Result<void>> addRemoteCandidate(VoiceIceCandidate candidate);

  /// Replaces the connection's configuration with [configuration] — a newer
  /// credential's — for the next gathering.
  Future<Result<void>> setConfiguration(RelayIceConfiguration configuration);

  /// Marks the next offer as an ICE restart, which gathers again against the
  /// configuration in force.
  Future<Result<void>> restartIce();

  /// Closes the connection and frees it. Safe to call more than once.
  Future<void> close();
}

/// The state of one platform connection: `RTCPeerConnectionState`.
enum VoiceMediaState {
  fresh,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

sealed class VoicePeerMediaEvent {
  const VoicePeerMediaEvent();
}

/// One local candidate. Relay-only ICE gathers relay candidates only.
final class VoiceLocalCandidateGathered extends VoicePeerMediaEvent {
  const VoiceLocalCandidateGathered(this.candidate);

  final VoiceIceCandidate candidate;

  @override
  String toString() => 'VoiceLocalCandidateGathered(<redacted>)';
}

/// The platform reports gathering complete. A hint, not a boundary: it names
/// no generation, and a session a restart stopped can report it too.
final class VoiceCandidateGatheringComplete extends VoicePeerMediaEvent {
  const VoiceCandidateGatheringComplete();
}

final class VoiceMediaStateChanged extends VoicePeerMediaEvent {
  const VoiceMediaStateChanged(this.state);

  final VoiceMediaState state;
}

/// The call's microphone.
///
/// One capture is shared by every connection of a call: each connection takes
/// a hold on it when it is created and gives the hold back when it closes.
abstract interface class VoiceLocalAudioPort implements Port {
  /// A hold on the call's one local audio track, capturing from the first
  /// hold until the last is released.
  ///
  /// **This never asks for the microphone permission, and it must not be
  /// reached without it.** The join asks, at the join and at no other time
  /// (§N rule 11). The platform implementation captures through
  /// `getUserMedia`, which on Android asks for `RECORD_AUDIO` by itself when
  /// it is missing (ADR-078), so a hold taken before the join's own request
  /// would put the system prompt in front of the user from here.
  Future<Result<VoiceLocalAudio>> acquire();
}

/// One hold on the call's local audio track.
abstract interface class VoiceLocalAudio {
  /// Gives the hold back. The track stops once no hold remains. Safe to call
  /// more than once.
  Future<void> release();
}
