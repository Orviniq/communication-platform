import 'dart:async';

import 'package:communication_platform/app/config/app_environment.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/app_shell/presentation/app_shell.dart';
import 'package:communication_platform/features/app_shell/presentation/live_shell_status.dart';
import 'package:communication_platform/features/authentication/presentation/authentication_route_state.dart';
import 'package:communication_platform/features/authentication/presentation/login_page.dart';
import 'package:communication_platform/features/authentication/presentation/pending_activation_page.dart';
import 'package:communication_platform/features/authentication/presentation/pre_auth_security_notice_page.dart';
import 'package:communication_platform/features/authentication/presentation/register_page.dart';
import 'package:communication_platform/features/authentication/presentation/session_restoration_page.dart';
import 'package:communication_platform/features/bootstrap/application/bootstrap_flow.dart';
import 'package:communication_platform/features/bootstrap/domain/bootstrap_model.dart';
import 'package:communication_platform/features/bootstrap/presentation/bootstrap_page.dart';
import 'package:communication_platform/features/contacts/presentation/contact_profile_page.dart';
import 'package:communication_platform/features/contacts/presentation/contacts_new_page.dart';
import 'package:communication_platform/features/contacts/presentation/edit_profile_page.dart';
import 'package:communication_platform/features/contacts/presentation/safety_number_page.dart';
import 'package:communication_platform/features/devices/presentation/device_enrollment_page.dart';
import 'package:communication_platform/features/devices/presentation/linked_devices_page.dart';
import 'package:communication_platform/features/diagnostics/presentation/diagnostics_page.dart';
import 'package:communication_platform/features/groups/presentation/add_group_members_page.dart';
import 'package:communication_platform/features/groups/presentation/create_group_page.dart';
import 'package:communication_platform/features/groups/presentation/edit_group_page.dart';
import 'package:communication_platform/features/groups/presentation/group_chat_page.dart';
import 'package:communication_platform/features/groups/presentation/group_info_page.dart';
import 'package:communication_platform/features/messaging/presentation/chats_list_page.dart';
import 'package:communication_platform/features/messaging/presentation/direct_chat_page.dart';
import 'package:communication_platform/features/settings/presentation/about_page.dart';
import 'package:communication_platform/features/settings/presentation/appearance_page.dart';
import 'package:communication_platform/features/settings/presentation/recovery_rotation_page.dart';
import 'package:communication_platform/features/settings/presentation/safety_numbers_page.dart';
import 'package:communication_platform/features/settings/presentation/security_settings_page.dart';
import 'package:communication_platform/features/settings/presentation/settings_page.dart';
import 'package:communication_platform/features/synchronization/presentation/sustained_delivery_page.dart';
import 'package:communication_platform/features/voice/presentation/create_voice_room_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_call_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_info_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_room_invite_page.dart';
import 'package:communication_platform/features/voice/presentation/voice_rooms_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

typedef AppRouteGuard =
    FutureOr<String?> Function(BuildContext context, GoRouterState state);

GoRouter createAppRouter({
  required AppEnvironment environment,
  AppRouteGuard? guard,
  AppShellStatus status = const AppShellStatus(),
  String initialLocation = '/chats',
  BootstrapFlow? bootstrapFlow,
  BootstrapPlatform bootstrapPlatform = BootstrapPlatform.android,
  AuthenticationRouteState? authenticationRouteState,
}) => GoRouter(
  initialLocation: initialLocation,
  refreshListenable: authenticationRouteState,
  redirect: (context, state) {
    if (state.uri.path == '/') {
      return '/chats';
    }
    final authenticationRedirect = authenticationRouteState?.redirect(
      state.uri.path,
      state.uri.toString(),
    );
    if (authenticationRedirect != null) {
      return authenticationRedirect;
    }
    return guard?.call(context, state);
  },
  routes: [
    if (bootstrapFlow != null)
      GoRoute(
        path: '/connection',
        pageBuilder: (context, state) => _page(
          context,
          state,
          BootstrapPage(
            flow: bootstrapFlow,
            platform: bootstrapPlatform,
            environment: environment,
            onResolved: (navigation) {
              switch (navigation.destination) {
                case BootstrapDestination.login:
                  context.go('/login', extra: navigation);
                case BootstrapDestination.application:
                  context.go(
                    navigation.offline ? '/chats?offline=true' : '/chats',
                  );
              }
            },
          ),
        ),
      ),
    GoRoute(
      path: '/login',
      pageBuilder: (context, state) {
        final username = switch (state.extra) {
          BootstrapNavigation(:final rememberedUsername) => rememberedUsername,
          final String username => username,
          _ => null,
        };
        return _page(
          context,
          state,
          authenticationRouteState == null
              ? const LoginRouteBoundaryPage()
              : LoginPage(initialUsername: username),
        );
      },
    ),
    // Registered unconditionally. The security notice is static content with
    // three entry points - the pre-login links, Settings, and a deep link - and
    // none of them may depend on whether authentication happens to be wired
    // into this composition (ADR-045).
    GoRoute(
      path: '/security-notice',
      pageBuilder: (context, state) =>
          _page(context, state, const PreAuthSecurityNoticePage()),
    ),
    if (authenticationRouteState != null) ...[
      GoRoute(
        path: '/session-restoring',
        pageBuilder: (context, state) =>
            _page(context, state, const SessionRestorationPage()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) =>
            _page(context, state, const RegisterPage()),
      ),
      GoRoute(
        path: '/pending-activation',
        pageBuilder: (context, state) => _page(
          context,
          state,
          PendingActivationPage(username: state.extra as String?),
        ),
      ),
      GoRoute(
        path: '/encryption-setup',
        pageBuilder: (context, state) =>
            _page(context, state, const DeviceEnrollmentPage()),
      ),
    ],
    GoRoute(
      path: '/contacts/:userId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        ContactProfilePage(userId: state.pathParameters['userId']!),
      ),
      routes: [
        GoRoute(
          path: 'safety',
          pageBuilder: (context, state) => _page(
            context,
            state,
            SafetyNumberPage(userId: state.pathParameters['userId']!),
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/groups/new',
      pageBuilder: (context, state) =>
          _page(context, state, const CreateGroupPage()),
    ),
    GoRoute(
      path: '/groups/:groupId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        GroupChatPage(groupId: state.pathParameters['groupId']!),
      ),
      routes: [
        GoRoute(
          path: 'info',
          pageBuilder: (context, state) => _page(
            context,
            state,
            GroupInfoPage(groupId: state.pathParameters['groupId']!),
          ),
        ),
        GoRoute(
          path: 'edit',
          pageBuilder: (context, state) => _page(
            context,
            state,
            EditGroupPage(groupId: state.pathParameters['groupId']!),
          ),
        ),
        GoRoute(
          path: 'add-members',
          pageBuilder: (context, state) => _page(
            context,
            state,
            AddGroupMembersPage(groupId: state.pathParameters['groupId']!),
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/saved-messages',
      pageBuilder: (context, state) => _page(
        context,
        state,
        SavedMessagesPage(
          conversationId: state.uri.queryParameters['conversationId'],
        ),
      ),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        final bootstrapOffline = state.uri.queryParameters['offline'] == 'true';
        return LiveShellStatus(
          base: bootstrapOffline
              ? status.copyWith(connection: AppConnectionState.offline)
              : status,
          location: state.uri.path,
          builder: (status) => AppShell(
            environment: environment,
            navigationShell: navigationShell,
            location: state.uri.path,
            status: status,
          ),
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/chats',
              pageBuilder: (context, state) =>
                  _page(context, state, const ChatsListPage()),
              routes: [
                GoRoute(
                  path: 'new',
                  pageBuilder: (context, state) =>
                      _page(context, state, const ContactsNewPage()),
                ),
                GoRoute(
                  path: 'conversation/:conversationId',
                  pageBuilder: (context, state) => _page(
                    context,
                    state,
                    DirectChatPage(
                      conversationId: state.pathParameters['conversationId']!,
                      peerUserId:
                          state.uri.queryParameters['peer'] ?? 'unknown',
                    ),
                  ),
                ),
                GoRoute(
                  path: 'direct/:userId',
                  pageBuilder: (context, state) => _page(
                    context,
                    state,
                    DirectChatPage(peerUserId: state.pathParameters['userId']!),
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/voice-rooms',
              pageBuilder: (context, state) =>
                  _page(context, state, const VoiceRoomsPage()),
              routes: [
                // Before `:roomId`, which would otherwise take `new` as an id.
                GoRoute(
                  path: 'new',
                  pageBuilder: (context, state) =>
                      _page(context, state, const CreateVoiceRoomPage()),
                ),
                // The room's 32-byte id in hex: a fixed path cannot name a
                // room (ADR-077 D12).
                GoRoute(
                  path: ':roomId',
                  pageBuilder: (context, state) => _page(
                    context,
                    state,
                    VoiceRoomInfoPage(roomId: state.pathParameters['roomId']!),
                  ),
                  routes: [
                    GoRoute(
                      path: 'call',
                      pageBuilder: (context, state) => _page(
                        context,
                        state,
                        VoiceCallPage(roomId: state.pathParameters['roomId']!),
                      ),
                    ),
                    GoRoute(
                      path: 'invite',
                      pageBuilder: (context, state) => _page(
                        context,
                        state,
                        VoiceRoomInvitePage(
                          roomId: state.pathParameters['roomId']!,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) =>
                  _page(context, state, const SettingsPage()),
              routes: [
                GoRoute(
                  path: 'appearance',
                  pageBuilder: (context, state) =>
                      _page(context, state, const AppearancePage()),
                ),
                // Security and recovery, and the two screens behind it.
                // Both are reached only from here: neither is ever
                // suggested, prompted or linked from a conversation.
                GoRoute(
                  path: 'security',
                  pageBuilder: (context, state) =>
                      _page(context, state, const SecuritySettingsPage()),
                  routes: [
                    GoRoute(
                      path: 'recovery',
                      pageBuilder: (context, state) =>
                          _page(context, state, const RecoveryRotationPage()),
                    ),
                    GoRoute(
                      path: 'safety-numbers',
                      pageBuilder: (context, state) =>
                          _page(context, state, const SafetyNumbersPage()),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'about',
                  pageBuilder: (context, state) =>
                      _page(context, state, const AboutPage()),
                  routes: [
                    GoRoute(
                      path: 'diagnostics',
                      pageBuilder: (context, state) =>
                          _page(context, state, const DiagnosticsPage()),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'profile',
                  pageBuilder: (context, state) =>
                      _page(context, state, const EditProfilePage()),
                ),
                GoRoute(
                  path: 'linked-devices',
                  pageBuilder: (context, state) =>
                      _page(context, state, const LinkedDevicesPage()),
                ),
                // Reached only from Settings, and deliberately not from
                // anywhere the application can send a user on its own: this
                // capability is never suggested, only found.
                GoRoute(
                  path: 'receiving-while-closed',
                  pageBuilder: (context, state) =>
                      _page(context, state, const SustainedDeliveryPage()),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

Page<void> _page(BuildContext context, GoRouterState state, Widget child) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: reduceMotion ? Duration.zero : AppMotion.route,
    reverseTransitionDuration: reduceMotion ? Duration.zero : AppMotion.route,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (reduceMotion) {
        return child;
      }
      final direction = Directionality.of(context) == TextDirection.ltr
          ? 1.0
          : -1.0;
      final offset = Tween<Offset>(
        begin: Offset(0.025 * direction, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: AppMotion.enter));
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          key: const ValueKey('app-route-spatial-transition'),
          position: animation.drive(offset),
          child: child,
        ),
      );
    },
  );
}
