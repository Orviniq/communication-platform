import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/app/config/group_production_gate.dart';
import 'package:communication_platform/core/result/failure.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';

/// Non-cryptographic local preview. It never emits a ciphersuite identifier,
/// KeyPackage, Welcome, or production-compatible ciphertext.
final class DevelopmentInMemoryGroupMls implements GroupMlsCryptoPort {
  DevelopmentInMemoryGroupMls.forDevelopmentPreview(
    GroupDevelopmentPreviewPermit permit, {
    int seed = 1,
  }) : _counter = seed;

  DevelopmentInMemoryGroupMls.forTests({int seed = 1}) : _counter = seed;

  int _counter;

  @override
  Future<Result<GroupMlsTransportProbe>> probeIncomingTransport(
    Uint8List mlsObject,
  ) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupTransition>> prepareCreate(
    GroupCreationIntent intent,
  ) async {
    final groupId = _nextHex(32, 'group');
    final operation = CreateGroupOperation(
      metadata: intent.metadata,
      invitationPolicy: intent.invitationPolicy,
      historySharingPolicy: intent.historySharingPolicy,
      initialMembers: intent.members,
    );
    return Result.success(
      _prepareControl(
        groupId: groupId,
        revision: 1,
        previousHash: null,
        epoch: 1,
        operation: operation,
        actorUserId: intent.creatorUserId,
        actorDeviceId: intent.creatorDeviceId,
        createdMs: intent.createdMs,
        recipientUserIds: intent.members.map((member) => member.userId),
      ),
    );
  }

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingWelcome({
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupTransition>> prepareControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
  }) async {
    if (currentOpaqueMlsState.isEmpty) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    return Result.success(
      _prepareControl(
        groupId: current.groupId,
        revision: current.controlRevision + 1,
        previousHash: current.controlStateHash,
        epoch: current.acceptedEpoch + (operation.changesMembership ? 1 : 0),
        operation: operation,
        actorUserId: actorUserId,
        actorDeviceId: actorDeviceId,
        createdMs: createdMs,
        recipientUserIds: current.activeMembers.map((member) => member.userId),
      ),
    );
  }

  PreparedGroupTransition _prepareControl({
    required String groupId,
    required int revision,
    required String? previousHash,
    required int epoch,
    required GroupControlOperation operation,
    required String actorUserId,
    required String actorDeviceId,
    required int createdMs,
    required Iterable<String> recipientUserIds,
  }) {
    final event = GroupControlEvent(
      eventId: _nextHex(16, 'event'),
      groupId: groupId,
      revision: revision,
      previousControlStateHash: previousHash,
      mlsEpoch: epoch,
      mlsCommitHash: operation.changesMembership
          ? _digestHex('preview-commit|$groupId|$revision')
          : null,
      signerUserId: actorUserId,
      signerDeviceId: actorDeviceId,
      createdMs: createdMs,
      operation: operation,
    );
    final canonical = Uint8List.fromList(
      utf8.encode(event.deterministicProjection),
    );
    final controlHash = _digestHex(
      'preview-control|${event.deterministicProjection}',
    );
    final signed = SignedGroupControlEvent(
      event: event,
      controlStateHash: controlHash,
      canonicalBytes: canonical,
      signature: Uint8List.fromList([
        ..._digest('preview-signature-a|$controlHash'),
        ..._digest('preview-signature-b|$controlHash'),
      ]),
    );
    return PreparedGroupTransition(
      signedControl: signed,
      newOpaqueMlsState: Uint8List.fromList(
        utf8.encode('DEVELOPMENT-PREVIEW-STATE|$groupId|$epoch|$controlHash'),
      ),
      mlsObject: Uint8List.fromList(
        utf8.encode('DEVELOPMENT-PREVIEW-CONTROL|$controlHash'),
      ),
      mutationId: 'preview-control-${event.eventId}',
      recipientUserIds: recipientUserIds,
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> prepareApplicationMessage({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required String senderUserId,
    required String senderDeviceId,
    required String text,
    required int createdMs,
  }) async {
    if (currentOpaqueMlsState.isEmpty) {
      return const Result.failure(
        SecurityFailure(SecurityFailureKind.integrityCheckFailed),
      );
    }
    final messageId = _nextHex(16, 'message');
    final marker = _digestHex(
      'preview-message|${current.groupId}|$messageId|$senderUserId|$text',
    );
    return Result.success(
      PreparedGroupMessage(
        groupId: current.groupId,
        messageId: messageId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        text: text,
        createdMs: createdMs,
        epoch: current.acceptedEpoch,
        newOpaqueMlsState: Uint8List.fromList(
          utf8.encode(
            'DEVELOPMENT-PREVIEW-STATE|${current.groupId}|'
            '${current.acceptedEpoch}|$marker',
          ),
        ),
        mlsObject: Uint8List.fromList(
          utf8.encode('DEVELOPMENT-PREVIEW-MESSAGE|$marker'),
        ),
        operationId: 'preview-message-$messageId',
        recipientUserIds: current.activeMembers.map((member) => member.userId),
      ),
    );
  }

  @override
  Future<Result<PreparedGroupMessage>> inspectIncomingApplication({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<PreparedGroupTransition>> inspectIncomingControl({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required Uint8List mlsObject,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  @override
  Future<Result<GroupForkResolution>> reconcileFork({
    required GroupState current,
    required Uint8List currentOpaqueMlsState,
    required List<Uint8List> siblingCommits,
    required String localUserId,
    required String localDeviceId,
  }) async => const Result.failure(
    UnsupportedProtocolFailure(UnsupportedProtocolFailureKind.capability),
  );

  String _nextHex(int byteLength, String domain) {
    final value = _digest('$domain|${_counter++}');
    final repeated = <int>[];
    while (repeated.length < byteLength) {
      repeated.addAll(_digest('$domain|${_counter++}|${value.length}'));
    }
    return repeated
        .take(byteLength)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _digestHex(String input) => _digest(
    input,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  List<int> _digest(String input) {
    final bytes = utf8.encode(input);
    var state = 0x811c9dc5;
    for (final byte in bytes) {
      state = ((state ^ byte) * 0x01000193) & 0xffffffff;
    }
    return List<int>.generate(32, (index) {
      state = ((state ^ (index + 1)) * 0x01000193) & 0xffffffff;
      return (state >>> ((index % 4) * 8)) & 0xff;
    });
  }
}
