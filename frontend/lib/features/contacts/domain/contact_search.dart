import 'package:communication_platform/features/contacts/domain/contact_model.dart';

/// Whether [contact] matches [needle], a query already trimmed and in lower
/// case.
///
/// The one contact rule, so that no two surfaces that filter contacts can
/// disagree about which contact a query finds. A contact matches on its
/// username, which the server stores in lower case (accounts `API.md`), and on
/// its display name only when it is verified: an unverified contact's display
/// name is never shown, so a match on it would surface a row for a word the
/// reader cannot see on it. An empty [needle] matches every contact.
bool contactMatchesSearch(ContactProjection contact, String needle) =>
    contact.username.contains(needle) ||
    (contact.canUseAuthenticatedProfile &&
        contact.presentationName.toLowerCase().contains(needle));
