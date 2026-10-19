import 'dart:async';

import 'package:communication_platform/app/dependencies/contact_providers.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/groups/domain/group_member_names.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The names this phone shows for the members of a group.
///
/// One source for every group screen: Group Info, the member sheet, the author
/// labels, the reply quotes and the reader list. A name is never read from the
/// group, which carries user ids and roles only. It comes from the local
/// contacts store, which holds the activated directory with each user's trust
/// state:
///
/// - this account is named by the username its session holds;
/// - a verified contact by the display name it authenticated, else by its
///   directory username;
/// - a member the store holds no row for is absent, and the directory is read
///   once, after the first answer, to fill the store. The answer that follows
///   names that member if the directory lists it.
///
/// A member that stays absent is worded "Unknown member" by the screen.
final groupMemberNamesProvider = StreamProvider.autoDispose
    .family<GroupMemberNames, GroupMemberNamesRequest>((ref, request) async* {
      final own = ref.watch(
        authenticationControllerProvider.select(
          (state) => (userId: state.userId, username: state.username),
        ),
      );
      final ownUserId = own.userId?.toLowerCase();
      final ownUsername = own.username?.trim();
      final local = await ref.watch(contactLocalProvider.future);
      // Read through the container once the lookup runs: it may outlive the
      // last listener of this provider, and a `ref` cannot be read after that.
      final container = ref.container;
      var lookedUp = false;
      await for (final contacts in local.watchContacts(
        ownUserId: ownUserId ?? '',
      )) {
        final byId = {
          for (final contact in contacts) contact.userId.toLowerCase(): contact,
        };
        final entries = <String, GroupMemberName>{};
        var missing = false;
        for (final userId in request.userIds) {
          if (userId == ownUserId) {
            if (ownUsername != null && ownUsername.isNotEmpty) {
              entries[userId] = GroupMemberName(
                name: ownUsername,
                verified: false,
              );
            }
            continue;
          }
          final contact = byId[userId];
          if (contact == null) {
            missing = true;
            continue;
          }
          final name = contact.presentationName.trim();
          if (name.isEmpty) continue;
          entries[userId] = GroupMemberName(
            name: name,
            verified: contact.trustState == ContactTrustState.verified,
          );
        }
        yield GroupMemberNames(entries);
        if (missing && !lookedUp) {
          lookedUp = true;
          unawaited(_fillDirectory(container));
        }
      }
    });

/// Reads the directory into the contacts store, so the stream above names the
/// members it had no row for.
///
/// Best effort. An offline phone, a refused read and a thrown error all leave
/// the store as it was, and the member stays "Unknown member" until the next
/// time the screen opens.
Future<void> _fillDirectory(ProviderContainer container) async {
  try {
    final service = await container.read(directoryServiceProvider.future);
    await service.refresh();
  } on Object {
    // Nothing is logged: the failure names no member and changes nothing.
  }
}
