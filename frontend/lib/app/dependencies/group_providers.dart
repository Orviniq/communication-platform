import 'package:communication_platform/app/dependencies/core_providers.dart';
import 'package:communication_platform/app/dependencies/local_storage_providers.dart';
import 'package:communication_platform/app/dependencies/messaging_providers.dart';
import 'package:communication_platform/features/groups/application/group_outbound_dispatcher.dart';
import 'package:communication_platform/features/groups/application/group_use_cases.dart';
import 'package:communication_platform/features/groups/application/ports/group_ports.dart';
import 'package:communication_platform/features/groups/domain/group_model.dart';
import 'package:communication_platform/features/groups/infrastructure/drift_group_repository.dart';
import 'package:communication_platform/features/groups/infrastructure/pairwise_group_outbound_envelope_adapter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final groupRepositoryProvider = FutureProvider<GroupRepositoryPort>((
  ref,
) async {
  final database = await ref.watch(localDatabaseProvider.future);
  return DriftGroupRepository(database);
});

typedef GroupScope = ({String userId, String deviceId});

final groupOutboundDispatcherProvider =
    FutureProvider.family<GroupOutboundDispatcher, GroupScope>((
      ref,
      scope,
    ) async {
      final repository = await ref.watch(groupRepositoryProvider.future);
      final fanout = await ref.watch(
        pairwiseFanoutCoordinatorProvider((
          userId: scope.userId,
          deviceId: scope.deviceId,
        )).future,
      );
      return GroupOutboundDispatcher(
        repository: repository,
        envelopes: PairwiseGroupOutboundEnvelopeAdapter(fanout),
      );
    });

final groupUseCasesProvider = FutureProvider<GroupUseCases>((ref) async {
  final repository = await ref.watch(groupRepositoryProvider.future);
  final clock = ref.watch(timeSourceProvider);
  return GroupUseCases(
    create: CreateGroup(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: false,
    ),
    mutate: MutateGroup(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: false,
    ),
    sendMessage: SendGroupMessage(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: false,
    ),
    acceptWelcome: AcceptGroupWelcome(repository: repository),
    applyIncomingMessage: ApplyIncomingGroupMessage(repository: repository),
  );
});

final groupProvider = StreamProvider.autoDispose.family<GroupState?, String>((
  ref,
  groupId,
) async* {
  final repository = await ref.watch(groupRepositoryProvider.future);
  yield* repository.watchGroup(groupId);
});

final groupMessagesProvider = StreamProvider.autoDispose
    .family<List<GroupMessage>, String>((ref, groupId) async* {
      final repository = await ref.watch(groupRepositoryProvider.future);
      yield* repository.watchMessages(groupId);
    });
