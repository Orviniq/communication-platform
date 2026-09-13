import 'package:communication_platform/app/config/group_production_gate.dart';
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

enum GroupFeatureAvailability {
  /// The in-memory fake, in a non-release development build. Nothing is sent.
  developmentPreview,

  /// The real closed-beta PQ MLS stack in the private experimental artifact.
  /// Group objects are transmitted over the pairwise transport, and the state
  /// they produce is disposable by decision (ADR-036, ADR-044).
  privateExperimental,

  /// The artifact the group stack belongs to, with the stack withheld on *this
  /// device* because the packaged native core it would load has not been
  /// observed running on this processor (ADR-055, narrowed to per-ABI by
  /// ADR-056).
  ///
  /// Distinct from [productionUnavailable] so the interface can say which of
  /// the two it is. Nothing is composed, nothing is uploaded and no screen is
  /// reachable in either, but only one of them is waiting on evidence.
  privateExperimentalWithheld,

  /// No group stack. Production always lands here; so does any build without a
  /// permit. Every group screen renders the closed gate instead.
  productionUnavailable;

  bool get isAvailable =>
      this == GroupFeatureAvailability.developmentPreview ||
      this == GroupFeatureAvailability.privateExperimental;
}

final groupFeatureAvailabilityProvider = Provider<GroupFeatureAvailability>((
  ref,
) {
  final environment = ref.watch(appEnvironmentProvider);
  final abi = ref.watch(runtimeAbiProvider);
  if (GroupProductionGate.developmentPreviewPermit(environment) != null) {
    return GroupFeatureAvailability.developmentPreview;
  }
  if (GroupProductionGate.privateExperimentalPermit(environment, abi) != null) {
    return GroupFeatureAvailability.privateExperimental;
  }
  if (GroupProductionGate.privateExperimentalWithheld(environment, abi)) {
    return GroupFeatureAvailability.privateExperimentalWithheld;
  }
  return GroupFeatureAvailability.productionUnavailable;
});

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
  final preview =
      ref.watch(groupFeatureAvailabilityProvider) ==
      GroupFeatureAvailability.developmentPreview;
  final clock = ref.watch(timeSourceProvider);
  return GroupUseCases(
    create: CreateGroup(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: preview,
    ),
    mutate: MutateGroup(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: preview,
    ),
    sendMessage: SendGroupMessage(
      repository: repository,
      clock: clock,
      developmentPreviewOnly: preview,
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
