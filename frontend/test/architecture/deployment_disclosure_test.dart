import 'dart:convert';
import 'dart:io';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/deployment_disclosure.dart';
import 'package:communication_platform/features/devices/application/acknowledge_deployment_disclosure.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _catalogue(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// The user-facing side of ADR-045 and ADR-052: what a build says it is, to
/// whom, what must move before that statement may change, and what is owed to
/// somebody who accepted an older one.
void main() {
  test('only a build that is handed to someone else carries a disclosure', () {
    // Production packages unsigned and cannot be installed (ADR-042), and the
    // development flavor is never distributed. Neither may render Private
    // Experimental wording, so temporary text cannot leak into a release that
    // no longer deserves it.
    expect(AppEnvironment.production.deploymentDisclosure, isNull);
    expect(AppEnvironment.development.deploymentDisclosure, isNull);
    expect(
      AppEnvironment.beta.deploymentDisclosure,
      same(DeploymentDisclosure.privateExperimental),
    );
  });

  test('the disclosure states every fact ADR-052 requires, in order', () {
    expect(DeploymentDisclosure.privateExperimental.points, const [
      DisclosurePoint.noIndependentReview,
      DisclosurePoint.bestEffortDelivery,
      DisclosurePoint.messagesExpireUnread,
      DisclosurePoint.deviceOnlyHistory,
      DisclosurePoint.recoveryExcludesHistory,
      DisclosurePoint.experimentalGroups,
      DisclosurePoint.unbuiltSurfaces,
      DisclosurePoint.intendedUse,
    ]);
    expect(
      DisclosurePoint.values.toSet(),
      DeploymentDisclosure.privateExperimental.points.toSet(),
      reason:
          'A point that exists but is never shown is a fact the decision '
          'recorded and the app withholds.',
    );
  });

  test('the revision cannot be raised, or forgotten, by hand', () {
    // This is the anti-skip rule ADR-052 added, and it closes the hole that let
    // revisions 2, 3 and 4 ship without anything checking that the number had
    // moved with the words. Editing any pinned string below fails the next
    // test; the only way to make that pass is to raise the point's `since`; and
    // raising `since` past the revision fails here. The bump is therefore
    // forced by the edit rather than remembered by a person.
    final disclosure = DeploymentDisclosure.privateExperimental;
    final highest = disclosure.points
        .map((point) => point.since)
        .reduce((a, b) => a > b ? a : b);
    expect(
      disclosure.revision,
      highest,
      reason: 'the revision is the highest point revision, never a free number',
    );
    for (final point in DisclosurePoint.values) {
      expect(
        point.since,
        greaterThanOrEqualTo(1),
        reason: '${point.name} must say when it last moved',
      );
      expect(
        point.since,
        lessThanOrEqualTo(disclosure.revision),
        reason: '${point.name} claims to be newer than the statement it is in',
      );
    }
  });

  test('the disclosure revision moves whenever the disclosure moves', () {
    // ADR-045 rejects periodic re-consent - repetition of an unchanged warning
    // measurably destroys it - and makes re-consent content-triggered instead.
    expect(DeploymentDisclosure.privateExperimental.revision, 8);

    final english = _catalogue('lib/l10n/app_en.arb');

    expect(english['disclosureBuildTitle'], 'What this build is');
    expect(
      english['disclosureNoIndependentReview'],
      contains('Nobody outside'),
    );
    expect(
      english['disclosureBestEffortDelivery'],
      'While this app is open, messages arrive as they are sent. While it is '
      'closed, your phone looks for new ones on its own schedule — fifteen '
      'minutes apart at best, usually far less often, and not at all while it '
      'is saving battery, while Data Saver is on and you are using mobile '
      'data, if you have not opened the app for several days, or if you have '
      'force-stopped it. In Settings you can turn on receiving while closed, '
      'which does better on most phones but uses more battery and shows a '
      'permanent notice while it is on. Nothing about any of this is '
      'guaranteed, so do not rely on it for anything urgent.',
    );
    // Two wordings for one point, and both are pinned. The second states the
    // deployment's own retention window; the first is what a reader is shown
    // until `GET /api/v1/config` has answered, because `ENVELOPE_TTL_DAYS` has
    // no other observable and this build's default would be a guess stated as
    // fact (revision 8).
    expect(
      english['disclosureMessagesExpireUnread'],
      'A message waits on the server only until your phone collects it. After '
      'a time set by whoever runs the server, whatever is still waiting is '
      'deleted and never arrives, and you will not be told which messages '
      'those were. If you go a long time without opening the app, assume you '
      'have missed some.',
    );
    expect(
      english['disclosureMessagesExpireUnreadDays'],
      'A message waits on the server only until your phone collects it. '
      'Anything still waiting after {days} days is deleted and never arrives, '
      'and you will not be told which messages those were. If you go a long '
      'time without opening the app, assume you have missed some.',
    );
    expect(
      english['disclosureDeviceOnlyHistory'],
      'Your messages are stored only on this phone. The server keeps no copy '
      'of your history and no backup exists, so uninstalling the app destroys '
      'it permanently.',
    );
    expect(
      english['disclosureRecoveryExcludesHistory'],
      'Your recovery secret restores your account identity on a new device. '
      'It never restores messages; those can only come from another device of '
      'yours that still works.',
    );
    expect(
      english['disclosureExperimentalGroups'],
      'Group chats use experimental encryption that is not finished, not '
      'standardised, and has not been independently reviewed. An update can '
      'reset a group and delete everything in it. On a phone whose processor '
      'it has not been tested on, group chats are switched off instead.',
    );
    expect(
      english['disclosureUnbuiltSurfaces'],
      'Some things you can see are not built yet: voice rooms and file '
      'attachments do nothing, and the display name and photo you choose are '
      'not published — other people see the username you registered with.',
    );
    expect(
      english['disclosureIntendedUse'],
      'This build is for trying out among people who already trust each '
      'other. It is not suitable if your safety depends on your messages '
      'staying private.',
    );
  });

  test('the disclosure and the composed delivery path agree', () {
    // Revision 2 exists because revision 1 said "There are no notifications",
    // and this build posts them. Revision 3 exists because revision 2 said
    // nothing runs in the background, and this build schedules a deferred
    // catch-up. Revision 4 exists because revision 3 described the deferred
    // catch-up as the whole of what happens while the app is closed, and this
    // build carries an opt-in capability that does better. The text and the
    // composition must move together in both directions: a build that composes
    // a background path may not carry text denying it, and text promising
    // catch-up may not ship without the path.
    final english = _catalogue('lib/l10n/app_en.arb');
    final delivery = english['disclosureBestEffortDelivery']! as String;

    expect(
      File('lib/app/app.dart').readAsStringSync(),
      contains('messageAlertControllerProvider'),
      reason: 'the application root is what makes an alert possible at all',
    );
    expect(
      delivery.toLowerCase(),
      isNot(contains('there are no notifications')),
      reason: 'the artifact posts them',
    );
    expect(
      delivery.toLowerCase(),
      isNot(contains('nothing runs in the background')),
      reason: 'the artifact schedules a deferred catch-up',
    );
    // The three things the text promises, and the three things the artifact
    // must therefore contain: a periodic job at the platform floor, a network
    // constraint, and persistence across a restart.
    final scheduler = File(
      'android/app/src/main/kotlin/com/example/communication_platform/'
      'BackgroundDelivery.kt',
    ).readAsStringSync();
    expect(scheduler, contains('setPeriodic('));
    expect(scheduler, contains('JobInfo.NETWORK_TYPE_ANY'));
    expect(scheduler, contains('setPersisted(true)'));
    // And the limits it must keep stating, because no design removes them.
    // Data Saver joined them at revision 5: `NETWORK_TYPE_ANY` asks for any
    // network and gets none when Data Saver is on and the connection is
    // metered, which is the connection most of these users pay for.
    for (final promise in const [
      'fifteen minutes apart at best',
      'force-stopped',
      'Data Saver',
    ]) {
      expect(delivery, contains(promise));
    }
    // Revision 4's addition, and the three things it may not omit: that the
    // better tier exists, that it costs something the user can see, and that it
    // is still not a guarantee. A build that ships the capability while the
    // disclosure denies it, or that describes it without its cost, fails here.
    final sustained = File(
      'lib/features/synchronization/presentation/sustained_delivery_page.dart',
    );
    expect(sustained.existsSync(), isTrue);
    for (final promise in const [
      'In Settings you can turn on receiving while closed',
      'uses more battery',
      'permanent notice',
      'Nothing about any of this is guaranteed',
    ]) {
      expect(delivery, contains(promise));
    }
  });

  test('an alert surface may not deny a delivery path the build composes', () {
    // The Settings row is a claim about delivery in its own right, and until
    // ADR-052 it contradicted the two headless paths beside it. Both of these
    // reconcile alerts with no activity in the process, so no user-facing
    // string may say alerts need one.
    for (final path in const [
      'lib/app/dependencies/deferred_delivery_catch_up.dart',
      'lib/app/dependencies/sustained_delivery_run.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('ReconcileMessageAlerts('),
        reason: '$path is why an alert can reach a closed application',
      );
    }
    // The exact retracted claim, in both catalogues. "Only" itself is fine and
    // load-bearing elsewhere in the sentence - what may not return is the
    // clause tying an alert to a running application.
    const retracted = {
      'lib/l10n/app_en.arb': 'while this app is running',
      'lib/l10n/app_fa.arb': 'این برنامه در حال اجرا باشد',
    };
    for (final entry in retracted.entries) {
      final row = _catalogue(entry.key)['settingsNotificationsOn']! as String;
      expect(
        row.toLowerCase().contains(entry.value.toLowerCase()),
        isFalse,
        reason: '${entry.key} still restricts alerts to a running application',
      );
    }
    expect(
      _catalogue('lib/l10n/app_en.arb')['settingsNotificationsOn'],
      contains('while the app is closed'),
    );
  });

  test('the disclosure may not call a built surface unbuilt', () {
    // Revision 5 removed "search" from the unbuilt list. Search is composed:
    // the chat list filters on title and preview, and a conversation's own
    // search reads that conversation's whole local history. If either
    // filter is still here, the disclosure may not deny it.
    final chats = File(
      'lib/features/messaging/presentation/chats_list_page.dart',
    ).readAsStringSync();
    expect(chats, contains('item.title.toLowerCase().contains(query)'));
    // The in-conversation filter moved into one shared surface after
    // ADR-052, so that a group conversation gets the same search rather
    // than a disabled button offering one. It is still the same filter
    // over the same unbounded projection, and it is now reached from more
    // screens, not fewer.
    final search = File(
      'lib/features/messaging/presentation/conversation_search.dart',
    ).readAsStringSync();
    expect(search, contains('text.toLowerCase().contains(needle)'));
    for (final path in const [
      'lib/features/messaging/presentation/chat_conversation_view.dart',
      'lib/features/groups/presentation/group_chat_page.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('showConversationSearch('),
        reason: '\$path offers the search the disclosure does not deny',
      );
    }

    final unbuilt =
        _catalogue('lib/l10n/app_en.arb')['disclosureUnbuiltSurfaces']!
            as String;
    expect(
      unbuilt.toLowerCase(),
      isNot(contains('search')),
      reason: 'the artifact searches; the claim was the thing that was wrong',
    );
    // And the two surfaces it still names must still be unbuilt.
    expect(unbuilt, contains('voice rooms'));
    expect(unbuilt, contains('file attachments'));
    expect(
      File(
        'lib/features/attachments/presentation/attachment_sheet.dart',
      ).readAsStringSync(),
      contains('attachmentsNotBuiltNotice'),
    );
  });

  test('the chat list states the scope it actually searches', () {
    // It matches title and last-message preview, so it may not borrow the
    // in-conversation notice, which promises this device's history (ADR-052).
    final chats = File(
      'lib/features/messaging/presentation/chats_list_page.dart',
    ).readAsStringSync();
    expect(chats, contains('chatsListSearchScopeNotice'));
    final english = _catalogue('lib/l10n/app_en.arb');
    expect(
      english['chatsListSearchScopeNotice'],
      contains('names and the latest message only'),
    );
    expect(english['chatsSearchHint'], 'Search names and the latest message');
  });

  test('the permanent sections name no feature this build cannot do', () {
    // These two sections outlive the deployment disclosure, so a capability
    // named in them goes stale every time the feature set moves. Until ADR-052
    // the first promised that "files" and "voice audio" were unreadable to the
    // server, in an artifact that can send neither.
    for (final path in const ['lib/l10n/app_en.arb', 'lib/l10n/app_fa.arb']) {
      final strings = _catalogue(path);
      final protects = (strings['enrollmentProtectsBody']! as String)
          .toLowerCase();
      for (final feature in const ['file', 'voice', 'audio', 'فایل', 'صدا']) {
        expect(
          protects.contains(feature),
          isFalse,
          reason: '$path promises "$feature" in a permanent section',
        );
      }
    }
    // And the limitation section must point at the screen by the name that
    // screen actually carries, rather than at "fingerprints".
    final english = _catalogue('lib/l10n/app_en.arb');
    expect(english['enrollmentDoesNotProtectBody'], contains('safety number'));
    expect(english['safetyTitle'], 'Safety number');
    expect(
      (english['enrollmentDoesNotProtectBody']! as String).toLowerCase(),
      isNot(contains('fingerprint')),
    );
    expect(
      (english['enrollmentDoesNotProtectBody']! as String).toLowerCase(),
      isNot(contains('social graph')),
    );
  });

  group('what a changed statement owes an earlier reader', () {
    const disclosure = DeploymentDisclosure.privateExperimental;

    test('a current reader is asked nothing', () {
      expect(disclosure.requiresReacknowledgement(8), isFalse);
      expect(disclosure.changedSince(8), isEmpty);
    });

    test('a reader from revision 7 sees only the retention point', () {
      // The client can state the deployment's retention window for the first
      // time. Nothing else moved, so nothing else is re-shown - repeating an
      // unchanged warning is what ADR-045 rejects.
      expect(disclosure.requiresReacknowledgement(7), isTrue);
      expect(disclosure.changedSince(7), {
        DisclosurePoint.messagesExpireUnread,
      });
    });

    test(
      'a reader from revision 5 or 6 sees the group and retention points',
      () {
        // ADR-055 withheld the group surface and ADR-056 reopened it on the one
        // ABI that was measured; revision 8 moved the retention point. Nothing
        // else they accepted has changed.
        for (final accepted in const [5, 6]) {
          expect(disclosure.requiresReacknowledgement(accepted), isTrue);
          expect(
            disclosure.changedSince(accepted),
            {
              DisclosurePoint.messagesExpireUnread,
              DisclosurePoint.experimentalGroups,
            },
            reason: 'a reader from revision $accepted',
          );
        }
      },
    );

    test('a reader from revision 4 sees exactly what moved', () {
      expect(disclosure.requiresReacknowledgement(4), isTrue);
      expect(disclosure.changedSince(4), {
        DisclosurePoint.bestEffortDelivery,
        DisclosurePoint.messagesExpireUnread,
        DisclosurePoint.deviceOnlyHistory,
        DisclosurePoint.experimentalGroups,
        DisclosurePoint.unbuiltSurfaces,
      });
    });

    test('a reader with no record is owed the whole statement', () {
      // Everyone who enrolled before ADR-052 is here. Nothing is known about
      // what they were shown, so nothing may be assumed read.
      expect(disclosure.requiresReacknowledgement(0), isTrue);
      expect(disclosure.changedSince(0), disclosure.points.toSet());
    });

    test('the record is durable, encrypted, and never lowered', () {
      final store = File(
        'lib/features/devices/infrastructure/'
        'drift_disclosure_acknowledgement_store.dart',
      ).readAsStringSync();
      expect(
        store,
        contains('database.localPreferences'),
        reason: 'the encrypted preference table, not a plaintext file',
      );
      expect(
        store,
        contains('if (existing >= revision)'),
        reason: 'a downgrade must not re-present an answered statement',
      );
      // And nothing about a person beyond the integer itself.
      for (final leak in const ['DateTime', 'deviceId', 'userId']) {
        expect(
          store.contains(leak),
          isFalse,
          reason: 'the acceptance record must not carry $leak',
        );
      }
    });

    test('enrollment records what was accepted, not merely that it was', () {
      final page = File(
        'lib/features/devices/presentation/device_enrollment_page.dart',
      ).readAsStringSync();
      expect(page, contains('_recordDisclosureAcceptance()'));
      expect(page, contains('acknowledgement.accept(revision:'));
      expect(
        page.indexOf('_recordDisclosureAcceptance()'),
        lessThan(page.indexOf('secureSetupCompleted()')),
        reason:
            'a fresh install must never meet the gate for a statement it has '
            'just answered',
      );
    });

    test('the gate sits above the router and cannot be routed past', () {
      final app = File('lib/app/app.dart').readAsStringSync();
      expect(app, contains('DisclosureChangeGate('));
      expect(
        app.indexOf('DisclosureChangeGate('),
        greaterThan(app.indexOf('routerConfig: _router')),
        reason: 'it wraps the routed child rather than being one of the routes',
      );
      final router = File('lib/app/routing/app_router.dart').readAsStringSync();
      expect(
        router.contains('DisclosureChangePage'),
        isFalse,
        reason: 'a route would be a route somebody can deep-link past',
      );
    });

    test('it never blocks a user who has not finished enrollment', () {
      final gate = File(
        'lib/features/devices/presentation/disclosure_change_gate.dart',
      ).readAsStringSync();
      expect(gate, contains('AuthenticationRouteAccess.fullScope'));
      expect(gate, contains('AuthenticationRouteAccess.offlineFullScope'));
      expect(gate, contains('if (!enrolled)'));
    });

    test('an unreadable record withholds the gate rather than the app', () {
      final useCase = File(
        'lib/features/devices/application/'
        'acknowledge_deployment_disclosure.dart',
      ).readAsStringSync();
      expect(
        useCase,
        contains('onFailure: (_) => DisclosureAcknowledgementState.unknown'),
        reason:
            'an honesty mechanism may not become a denial of service over a '
            'preference row',
      );
      expect(DisclosureAcknowledgementState.unknown.outstanding, isFalse);
    });
  });

  test('every string exists in both catalogues and neither is empty', () {
    // Catalogue-wide, not a hand-maintained key list. Before ADR-052 three
    // separate tests each pinned their own feature's keys, so a key added to
    // English alone passed every gate in the repository and shipped a screen
    // that fell back to English for the right-to-left half of the audience.
    final english = _catalogue('lib/l10n/app_en.arb');
    final persian = _catalogue('lib/l10n/app_fa.arb');
    String? Function(String) valueOf(Map<String, dynamic> catalogue) =>
        (key) => catalogue[key] is String ? catalogue[key] as String : null;

    final englishKeys = english.keys.where((key) => !key.startsWith('@'));
    final persianKeys = persian.keys
        .where((key) => !key.startsWith('@'))
        .toSet();

    for (final key in englishKeys) {
      expect(
        valueOf(english)(key),
        isNotNull,
        reason: 'English $key is not a string',
      );
      expect(
        persianKeys.contains(key),
        isTrue,
        reason: 'Persian is missing $key',
      );
      expect(
        valueOf(persian)(key)?.trim(),
        isNotNull,
        reason: 'Persian $key is not a string',
      );
      expect(
        valueOf(persian)(key)!.trim(),
        isNotEmpty,
        reason: 'Persian $key is empty',
      );
    }
    expect(
      persianKeys.difference(englishKeys.toSet()),
      isEmpty,
      reason: 'Persian carries keys English does not, so one of them is stale',
    );
  });

  test('no user-facing string calls this build a beta or claims assessment', () {
    // ADR-044 permits "beta" only where it names the frozen application ID, the
    // Gradle flavor or the AppEnvironment value, none of which are localized.
    // ADR-045 adds the assessment words: no surface may label itself audited,
    // reviewed, verified, supported, stable or production-ready.
    const forbidden = [
      'beta',
      'audited',
      'stable release',
      'production ready',
      'production-ready',
    ];
    for (final path in ['lib/l10n/app_en.arb', 'lib/l10n/app_fa.arb']) {
      final strings = _catalogue(path);
      for (final entry in strings.entries) {
        if (entry.key.startsWith('@') || entry.value is! String) {
          continue;
        }
        final value = (entry.value as String).toLowerCase();
        for (final word in forbidden) {
          expect(
            value.contains(word),
            isFalse,
            reason: '$path/${entry.key} says "$word" to a user',
          );
        }
      }
    }
  });

  test('the composed environment cannot disagree with the rendered one', () {
    // The disclosure is chosen by `appEnvironmentProvider`, while the shell
    // banner and the router take the environment as an argument. Both come from
    // one parameter of `bootstrap()`, and they must keep coming from it: if
    // they ever diverged, one build could render another build's statement.
    //
    // Since ADR-049 both entry points - the activity and the headless
    // catch-up - build that scope from `ApplicationRuntime`, so the
    // environment, the provisioned trust and the crypto core cannot differ
    // between them either.
    final runtime = File(
      'lib/app/dependencies/application_runtime.dart',
    ).readAsStringSync();
    final source = File('lib/app/bootstrap.dart').readAsStringSync();
    expect(
      runtime,
      contains('appEnvironmentProvider.overrideWithValue(environment)'),
    );
    expect(source, contains('ApplicationRuntime.create('));
    expect(source, contains('CommunicationPlatformApp('));
    expect(source, contains('environment: environment,'));
  });

  test('the maturity vocabulary only ever reads down from the app label', () {
    // Adding a value here that means "assessed", "supported" or "stable" would
    // let a surface claim more than the application-level Experimental label,
    // which no evidence in this repository supports.
    expect(SurfaceMaturity.values, const [
      SurfaceMaturity.experimental,
      SurfaceMaturity.notBuilt,
    ]);
  });

  test('the maturity badge is rendered from one place only', () {
    // A screen that hard-codes its own maturity wording is how four different
    // vocabularies reached users before ADR-045.
    final rendered = <String>[
      'lib/features/app_shell/presentation/structural_placeholder_page.dart',
      'lib/features/attachments/presentation/attachment_sheet.dart',
      'lib/features/contacts/presentation/edit_profile_page.dart',
      'lib/features/groups/presentation/group_components.dart',
      'lib/features/devices/presentation/security_notice_sections.dart',
    ];
    for (final path in rendered) {
      expect(
        File(path).readAsStringSync(),
        contains('SurfaceMaturity.'),
        reason: '$path renders a maturity label without the shared vocabulary',
      );
    }
  });
}
