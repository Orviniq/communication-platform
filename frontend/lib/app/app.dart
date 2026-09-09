import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/config/app_environment_banner.dart';
import 'package:communication_platform/app/dependencies/message_alerts.dart';
import 'package:communication_platform/app/dependencies/message_delivery.dart';
import 'package:communication_platform/app/dependencies/server_config_providers.dart';
import 'package:communication_platform/app/dependencies/settings.dart';
import 'package:communication_platform/app/dependencies/sustained_delivery.dart';
import 'package:communication_platform/app/design_system/app_theme.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/app/routing/app_router.dart';
import 'package:communication_platform/features/app_shell/presentation/app_shell.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_controller.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_route_state.dart';
import 'package:communication_platform/features/bootstrap/application/bootstrap_flow.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/devices/presentation/disclosure_change_gate.dart';
import 'package:communication_platform/features/settings/domain/appearance_model.dart';
import 'package:communication_platform/features/synchronization/domain/sustained_delivery_model.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Application root: global framework configuration and feature composition only.
class CommunicationPlatformApp extends ConsumerStatefulWidget {
  const CommunicationPlatformApp({
    required this.environment,
    this.locale,
    this.themeMode,
    this.routeGuard,
    this.shellStatus = const AppShellStatus(),
    this.initialLocation,
    this.bootstrapFlow,
    this.bootstrapPlatform = BootstrapPlatform.android,
    this.authenticationEnabled = false,
    super.key,
  });

  final AppEnvironment environment;

  /// An explicit override. Null means "whatever the user chose in
  /// Appearance", which is what a running application passes; a golden or a
  /// route harness passes a value so that its output does not depend on a
  /// stored preference.
  final Locale? locale;

  /// An explicit override, on the same terms as [locale].
  final ThemeMode? themeMode;
  final AppRouteGuard? routeGuard;
  final AppShellStatus shellStatus;
  final String? initialLocation;
  final BootstrapFlow? bootstrapFlow;
  final BootstrapPlatform bootstrapPlatform;
  final bool authenticationEnabled;

  @override
  ConsumerState<CommunicationPlatformApp> createState() =>
      _CommunicationPlatformAppState();
}

class _CommunicationPlatformAppState
    extends ConsumerState<CommunicationPlatformApp>
    with WidgetsBindingObserver {
  late final GoRouter _router;
  AuthenticationRouteState? _authenticationRouteState;
  ProviderSubscription<AuthenticationViewState>? _authenticationSubscription;
  ProviderSubscription<MessageDeliveryStage>? _deliverySubscription;
  ProviderSubscription<MessageAlertStage>? _alertSubscription;
  ProviderSubscription<SustainedDeliveryStatus>? _sustainedSubscription;
  ProviderSubscription<ServerConfigStage>? _serverConfigSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.authenticationEnabled) {
      final routeState = AuthenticationRouteState();
      _authenticationRouteState = routeState;
      _authenticationSubscription = ref.listenManual(
        authenticationControllerProvider,
        (previous, next) => routeState.update(next),
        fireImmediately: true,
      );
      // Message delivery is owned here, for the life of the application, and
      // deliberately not by a screen. `listenManual` is what makes that true:
      // subscriptions created in `build` are paused by Riverpod when their
      // widget leaves the view, and a paused delivery controller would stop
      // starting and stopping sessions the moment the user opened a route that
      // covered this one. Reading it is what instantiates it; the controller
      // itself decides when a session may run.
      _deliverySubscription = ref.listenManual(
        messageDeliveryControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      // Alerts are owned here for the same reason and by the same mechanism,
      // and separately from delivery: a delivery session that fails to compose
      // still leaves messages in the database that arrived before it and have
      // never been announced.
      _alertSubscription = ref.listenManual(
        messageAlertControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      // Sustained delivery is owned here for the same reason and by the same
      // mechanism. It is not part of the delivery session: the user's
      // arrangement with the operating system outlives any one session, and a
      // controller that stopped when a session did would answer *no* to the
      // question the next session asks it.
      _sustainedSubscription = ref.listenManual(
        sustainedDeliveryControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      // The published limits are read here for the same reason, and read
      // exactly once: the operator's numbers belong to the deployment rather
      // than to a screen, and nothing waits for them. The application is
      // already running on the stored answer, or on its own constants, by the
      // time this starts.
      _serverConfigSubscription = ref.listenManual(
        serverConfigControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      WidgetsBinding.instance.addObserver(this);
    }
    _router = createAppRouter(
      environment: widget.environment,
      guard: widget.routeGuard,
      status: widget.shellStatus,
      initialLocation:
          widget.initialLocation ??
          (widget.bootstrapFlow == null ? '/chats' : '/connection'),
      bootstrapFlow: widget.bootstrapFlow,
      bootstrapPlatform: widget.bootstrapPlatform,
      authenticationRouteState: _authenticationRouteState,
    );
  }

  /// The two things sustained delivery depends on are both changeable from
  /// outside this application - the notification permission and the
  /// battery-optimization exemption - and neither change is reported to it. The
  /// user leaving for system settings and coming back is when to re-read them,
  /// and it is also when a manufacturer's own battery screen has had its say.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sustainedSubscription != null) {
      unawaited(
        ref.read(sustainedDeliveryControllerProvider.notifier).refresh(),
      );
    }
  }

  @override
  void dispose() {
    if (_sustainedSubscription != null) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _serverConfigSubscription?.close();
    _sustainedSubscription?.close();
    _alertSubscription?.close();
    _deliverySubscription?.close();
    _authenticationSubscription?.close();
    _authenticationRouteState?.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    onGenerateTitle: (context) =>
        widget.environment.userFacingTitle(AppLocalizations.of(context)),
    // Watched here rather than passed down, so that changing either one in
    // Appearance rebuilds the whole application at once instead of leaving an
    // already-open route in the previous theme.
    locale: widget.locale ?? _localeOf(_appearance.language),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    themeMode: widget.themeMode ?? _themeModeOf(_appearance.theme),
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    highContrastTheme: AppTheme.highContrastLight(),
    highContrastDarkTheme: AppTheme.highContrastDark(),
    themeAnimationDuration: AppMotion.state,
    restorationScopeId: 'communication-platform-app',
    routerConfig: _router,
    // The disclosure gate sits above the router rather than inside it, so no
    // route, deep link or notification tap reaches the application without
    // passing it, and so there is no guard ordering to get wrong. It renders
    // its child untouched unless this build's statement has moved past what
    // the person using it accepted (ADR-052).
    builder: (context, child) => AppDesignSystem(
      child: DisclosureChangeGate(
        sessionComposed: widget.authenticationEnabled,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );

  /// What the user chose, or the phone's own settings when this composition
  /// has nowhere to have stored a choice.
  ///
  /// Guarded because this widget is also the unit under test in route and
  /// bootstrap harnesses that mount it without a `ProviderScope`. Those
  /// harnesses are testing routing and boot state, not appearance, and a root
  /// widget that will not render outside a production container would make
  /// every one of them a composition test.
  AppearancePreferences get _appearance {
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return AppearancePreferences.followSystem;
    }
    return ref.watch(appearancePreferencesProvider);
  }

  /// Null keeps `MaterialApp`'s own resolution, which follows the phone and
  /// falls back to the first supported locale when the phone is set to a
  /// language this application does not ship.
  static Locale? _localeOf(AppLanguagePreference language) {
    final code = language.languageCode;
    return code == null ? null : Locale(code);
  }

  static ThemeMode _themeModeOf(AppThemePreference theme) => switch (theme) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };
}
