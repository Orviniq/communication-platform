import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';

/// The single place that decides how a build names itself to the person using
/// it: the window title Android shows in the task switcher, and the persistent
/// configuration banner.
///
/// A build installed by other people may never be labelled as development, in
/// either surface. The launcher label lives in the Android product flavor —
/// "Communication Platform" for production, "Communication Platform
/// (Development)" for development — and [userFacingTitle] has to agree with it,
/// or one build presents two identities. Production carries no maturity
/// designation in either surface, by the owner's answer recorded in ADR-076.
extension AppEnvironmentBanner on AppEnvironment {
  /// The application title shown to the user, per build.
  String userFacingTitle(AppLocalizations l10n) => switch (this) {
    AppEnvironment.development => l10n.developmentAppTitle,
    AppEnvironment.production => l10n.appTitle,
  };

  /// The persistent configuration banner for this build, or null when the build
  /// is production and must show no banner at all.
  String? configurationBanner(AppLocalizations l10n) => switch (this) {
    AppEnvironment.development => l10n.developmentConfiguration,
    AppEnvironment.production => null,
  };
}
