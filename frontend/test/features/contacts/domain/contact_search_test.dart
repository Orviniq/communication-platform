import 'package:communication_platform/features/contacts/domain/contact_model.dart';
import 'package:communication_platform/features/contacts/domain/contact_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const profile = AuthenticatedProfile(
    displayName: 'Maryam Ahmadi',
    avatarSeed: 3,
    version: 1,
    authorDeviceId: 'device',
  );
  const verified = ContactProjection(
    userId: 'verified',
    username: 'first_friend',
    trustState: ContactTrustState.verified,
    authenticatedProfile: profile,
  );
  const unverified = ContactProjection(
    userId: 'unverified',
    username: 'second_friend',
    trustState: ContactTrustState.unverified,
    authenticatedProfile: profile,
  );

  test('a contact matches on any part of its username', () {
    expect(contactMatchesSearch(verified, 'first'), isTrue);
    expect(contactMatchesSearch(verified, 't_fr'), isTrue);
    expect(contactMatchesSearch(unverified, 'second_friend'), isTrue);
    expect(contactMatchesSearch(unverified, 'third'), isFalse);
  });

  test('a display name matches only on a verified contact', () {
    expect(contactMatchesSearch(verified, 'maryam'), isTrue);
    expect(contactMatchesSearch(verified, 'ahmadi'), isTrue);
    // The same authenticated profile, held by a contact nobody verified: its
    // name is never shown, so it never matches either.
    expect(contactMatchesSearch(unverified, 'maryam'), isFalse);
  });

  test(
    'a verified contact with no profile yet matches on its username only',
    () {
      const bare = ContactProjection(
        userId: 'bare',
        username: 'third_friend',
        trustState: ContactTrustState.verified,
      );
      expect(contactMatchesSearch(bare, 'third'), isTrue);
      expect(contactMatchesSearch(bare, 'maryam'), isFalse);
    },
  );

  test(
    'the needle is the caller\'s to normalize: it arrives in lower case',
    () {
      // The display name is lowered here; the needle is not touched, so a query
      // passed in as typed would miss.
      expect(contactMatchesSearch(verified, 'MARYAM'), isFalse);
      expect(contactMatchesSearch(verified, ' maryam'), isFalse);
    },
  );

  test('an empty needle matches every contact', () {
    expect(contactMatchesSearch(verified, ''), isTrue);
    expect(contactMatchesSearch(unverified, ''), isTrue);
  });

  test('Persian display names match Persian queries', () {
    const persian = ContactProjection(
      userId: 'persian',
      username: 'maryam_a',
      trustState: ContactTrustState.verified,
      authenticatedProfile: AuthenticatedProfile(
        displayName: 'مریم احمدی',
        avatarSeed: 1,
        version: 1,
        authorDeviceId: 'device',
      ),
    );
    expect(contactMatchesSearch(persian, 'احمدی'), isTrue);
    expect(contactMatchesSearch(persian, 'رضا'), isFalse);
  });
}
