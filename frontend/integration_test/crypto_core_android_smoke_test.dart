import 'dart:io';
import 'dart:typed_data';

import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/core/protocol/application_message_model.dart';
import 'package:communication_platform/core/protocol/crypto_core_model.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android loads the versioned Rust core in its isolate and verifies backend protocol vectors',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final cryptoCore = container.read(cryptoCoreProvider);
      addTearDown(cryptoCore.close);

      final capabilityResult = await cryptoCore.capabilities();
      expect(capabilityResult, isA<Success<CryptoCoreCapabilities>>());
      final capabilities =
          (capabilityResult as Success<CryptoCoreCapabilities>).value;
      expect(capabilities.abiVersion, CryptoCoreProtocolV1.abiVersion);
      expect(capabilities.supportsRequiredFoundation, isTrue);
      expect(capabilities.maxInputBytes, greaterThan(0));
      expect(capabilities.maxCborDepth, greaterThan(0));
      expect(capabilities.maxCborItems, greaterThan(0));

      expect(await cryptoCore.selfTest(), isA<Success<void>>());

      final applicationProtocol = container.read(applicationProtocolProvider);
      final applicationEvent = ApplicationEventRecord(
        version: 1,
        eventId: Uint8List.fromList(List<int>.filled(16, 1)),
        conversationId: Uint8List.fromList(List<int>.filled(32, 2)),
        kindValue: ApplicationEventKind.messageCreate.wireValue,
        senderUserId: Uint8List.fromList(List<int>.filled(16, 3)),
        senderDeviceId: Uint8List.fromList(List<int>.filled(16, 4)),
        senderCounter: 1,
        createdMs: 1700000000000,
        references: [Uint8List.fromList(List<int>.filled(16, 5))],
        body: MessageCreateBody(
          messageId: Uint8List.fromList(List<int>.filled(16, 6)),
          text: 'hello',
          replyToMessageId: Uint8List.fromList(List<int>.filled(16, 7)),
          quoteFallback: 'quoted',
        ),
      );
      final applicationBytes = await applicationProtocol.encode(
        applicationEvent,
      );
      expect(applicationBytes, isA<Success<Uint8List>>());
      final encodedApplicationBytes =
          (applicationBytes as Success<Uint8List>).value;
      expect(
        protocolBytesToHex(encodedApplicationBytes),
        'aa00010150010101010101010101010101010101010258200202020202020202'
        '0202020202020202020202020202020202020202020202020301045003030303'
        '0303030303030303030303030550040404040404040404040404040404040601'
        '071b0000018bcfe568000881500505050505050505050505050505050509a500'
        '50060606060606060606060606060606060100026568656c6c6f035007070707'
        '070707070707070707070707046671756f746564',
      );
      final decodedApplication = await applicationProtocol.decode(
        encodedApplicationBytes,
      );
      expect(decodedApplication, isA<Success<DecodedApplicationEvent>>());
      final decoded =
          (decodedApplication as Success<DecodedApplicationEvent>).value
              as SupportedApplicationEvent;
      expect(decoded.event.senderCounter, applicationEvent.senderCounter);
      expect(
        protocolBytesToHex(decoded.event.eventId),
        protocolBytesToHex(applicationEvent.eventId),
      );

      final identityCrypto = container.read(identityCryptoProvider);
      final localUser = Uint8List.fromList(List<int>.filled(16, 1));
      final localMaster = Uint8List.fromList(List<int>.filled(32, 2));
      final peerUser = Uint8List.fromList(List<int>.filled(16, 3));
      final peerMaster = Uint8List.fromList(List<int>.filled(32, 4));
      final forward = await identityCrypto.safetyFingerprint(
        localUserId: localUser,
        localMasterPublic: localMaster,
        peerUserId: peerUser,
        peerMasterPublic: peerMaster,
      );
      final reverse = await identityCrypto.safetyFingerprint(
        localUserId: peerUser,
        localMasterPublic: peerMaster,
        peerUserId: localUser,
        peerMasterPublic: localMaster,
      );
      expect(forward, isA<Success<SafetyFingerprint>>());
      expect(reverse, isA<Success<SafetyFingerprint>>());
      expect(
        (forward as Success<SafetyFingerprint>).value.digest,
        orderedEquals((reverse as Success<SafetyFingerprint>).value.digest),
      );

      expect(
        await identityCrypto.verifyIdentity(
          userId: peerUser,
          identity: PeerIdentityPublic(
            masterPublic: peerMaster,
            selfSigningPublic: Uint8List.fromList(List<int>.filled(32, 5)),
            userSigningPublic: Uint8List.fromList(List<int>.filled(32, 6)),
            masterSignature: Uint8List(64),
            version: 1,
          ),
        ),
        isA<FailureResult<void>>(),
      );
    },
    skip: !Platform.isAndroid,
  );
}
