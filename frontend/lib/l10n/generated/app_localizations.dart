import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa'),
  ];

  /// The provisional product name used until final branding is approved.
  ///
  /// In en, this message translates to:
  /// **'Communication Platform'**
  String get appTitle;

  /// The application title for visibly non-production builds.
  ///
  /// In en, this message translates to:
  /// **'Communication Platform (Development)'**
  String get developmentAppTitle;

  /// The application title for the Private Experimental build. It must match the Android launcher label set by the beta product flavor, and it must never read "Development": a build installed by other people may not present itself as a developer build (ADR-044).
  ///
  /// In en, this message translates to:
  /// **'Communication Platform (Experimental)'**
  String get experimentalAppTitle;

  /// A persistent warning that the running app is not production.
  ///
  /// In en, this message translates to:
  /// **'Development configuration'**
  String get developmentConfiguration;

  /// A persistent warning that the running app is the private experimental build. It deliberately does not say 'beta': ADR-044 holds that 'beta' implies a feature-complete, reviewed pre-release, which this is not. The key still names the flavor, because the .beta application ID is frozen and cannot follow the wording.
  ///
  /// In en, this message translates to:
  /// **'Private experimental build'**
  String get betaConfiguration;

  /// Bootstrap text shown before product screens are implemented.
  ///
  /// In en, this message translates to:
  /// **'Flutter foundation is ready'**
  String get foundationReady;

  /// No description provided for @bootstrapLoadingConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Loading secure configuration…'**
  String get bootstrapLoadingConfiguration;

  /// No description provided for @bootstrapCheckingStorage.
  ///
  /// In en, this message translates to:
  /// **'Checking protected storage…'**
  String get bootstrapCheckingStorage;

  /// No description provided for @bootstrapDiscoveringIdentity.
  ///
  /// In en, this message translates to:
  /// **'Checking this device…'**
  String get bootstrapDiscoveringIdentity;

  /// No description provided for @bootstrapValidatingTrust.
  ///
  /// In en, this message translates to:
  /// **'Verifying server trust…'**
  String get bootstrapValidatingTrust;

  /// No description provided for @bootstrapCheckingServer.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the server…'**
  String get bootstrapCheckingServer;

  /// No description provided for @bootstrapReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get bootstrapReady;

  /// No description provided for @notProvisionedTitle.
  ///
  /// In en, this message translates to:
  /// **'App not provisioned'**
  String get notProvisionedTitle;

  /// No description provided for @notProvisionedMessage.
  ///
  /// In en, this message translates to:
  /// **'Install a provisioned copy of this app from a trusted source. There is no connection bypass.'**
  String get notProvisionedMessage;

  /// No description provided for @protectedStorageUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Protected storage unavailable'**
  String get protectedStorageUnavailableTitle;

  /// No description provided for @protectedStorageUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'This device cannot safely open local identity or session data. Fix protected storage, then retry.'**
  String get protectedStorageUnavailableMessage;

  /// No description provided for @trustFailureTitle.
  ///
  /// In en, this message translates to:
  /// **'Server trust could not be verified'**
  String get trustFailureTitle;

  /// No description provided for @androidTrustFailureMessage.
  ///
  /// In en, this message translates to:
  /// **'The private certificate authority or server certificate pins do not match this provisioned app. Reinstall a trusted provisioned copy or contact the operator. You cannot continue past this check.'**
  String get androidTrustFailureMessage;

  /// No description provided for @webTrustFailureMessage.
  ///
  /// In en, this message translates to:
  /// **'Install the operator-provided private certificate authority in this operating system or browser, verify its fingerprint through the independent provisioning channel, then retry. The web app cannot install or bypass certificate trust.'**
  String get webTrustFailureMessage;

  /// No description provided for @serverUnreachableTitle.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the server'**
  String get serverUnreachableTitle;

  /// No description provided for @serverUnreachableMessage.
  ///
  /// In en, this message translates to:
  /// **'Check access to the provisioned server and try again.'**
  String get serverUnreachableMessage;

  /// No description provided for @retryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryAction;

  /// No description provided for @loginDestination.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginDestination;

  /// No description provided for @chatsDestination.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsDestination;

  /// No description provided for @voiceRoomsDestination.
  ///
  /// In en, this message translates to:
  /// **'Voice Rooms'**
  String get voiceRoomsDestination;

  /// No description provided for @settingsDestination.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsDestination;

  /// Badge for a surface that really transmits and encrypts but is neither reviewed nor standardised and whose state is disposable (ADR-045, SurfaceMaturity.experimental).
  ///
  /// In en, this message translates to:
  /// **'Experimental'**
  String get maturityExperimentalLabel;

  /// Badge for a surface that is routed and visible but has no implementation behind it (ADR-045, SurfaceMaturity.notBuilt). It replaces "Structural placeholder - not for shipping", which was developer wording and which contradicted itself in a build that does ship.
  ///
  /// In en, this message translates to:
  /// **'Not built yet'**
  String get maturityNotBuiltLabel;

  /// No description provided for @settingsLinkedDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Linked Devices'**
  String get settingsLinkedDevicesTitle;

  /// No description provided for @settingsLinkedDevicesSummary.
  ///
  /// In en, this message translates to:
  /// **'Review, rename, or revoke devices on this account'**
  String get settingsLinkedDevicesSummary;

  /// No description provided for @settingsAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceTitle;

  /// No description provided for @settingsNotificationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotificationsTitle;

  /// Revision 5 (ADR-052) corrected the second half. Until then this said an alert 'can only reach you while this app is running', which stopped being true when the deferred catch-up (ADR-049) and the sustained delivery run (ADR-051) began reconciling alerts from isolates with no activity at all.
  ///
  /// In en, this message translates to:
  /// **'On. An alert says only that something arrived, never who sent it or what it says. It can reach you while the app is closed, but only when your phone next lets the app look for messages.'**
  String get settingsNotificationsOn;

  /// No description provided for @settingsNotificationsOff.
  ///
  /// In en, this message translates to:
  /// **'Off. Nothing will tell you a message arrived unless you are looking at the app.'**
  String get settingsNotificationsOff;

  /// No description provided for @settingsNotificationsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available in this build.'**
  String get settingsNotificationsUnavailable;

  /// One action for every off state. Android shows its permission prompt when it still will, and this opens the system notification settings for this app when it will not, because a second refusal is permanent and the app can no longer prompt.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get settingsNotificationsTurnOn;

  /// Names the notification category in Android system settings for this app. Users adjust sound and importance there, so the name has to be recognisable out of context.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get notificationsChannelName;

  /// No description provided for @notificationsChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Tells you that something arrived. It never shows who sent it or what it says.'**
  String get notificationsChannelDescription;

  /// No description provided for @notificationsNewMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get notificationsNewMessage;

  /// The entire content of the alert. It names nobody and quotes nothing, so a lock screen, a heads-up over another app, and a notification-listener app all learn only that the app has something waiting.
  ///
  /// In en, this message translates to:
  /// **'New messages'**
  String get notificationsNewMessages;

  /// No description provided for @chatsPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats structure'**
  String get chatsPlaceholderTitle;

  /// No description provided for @chatsPlaceholderBody.
  ///
  /// In en, this message translates to:
  /// **'The routed conversation list and detail regions are ready for later feature pieces.'**
  String get chatsPlaceholderBody;

  /// No description provided for @voiceRoomsPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice rooms'**
  String get voiceRoomsPlaceholderTitle;

  /// No description provided for @voiceRoomsPlaceholderBody.
  ///
  /// In en, this message translates to:
  /// **'Voice rooms are not built yet. This build sends and receives no audio.'**
  String get voiceRoomsPlaceholderBody;

  /// No description provided for @settingsPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings structure'**
  String get settingsPlaceholderTitle;

  /// No description provided for @settingsPlaceholderBody.
  ///
  /// In en, this message translates to:
  /// **'The routed settings list and detail regions are ready for later feature pieces.'**
  String get settingsPlaceholderBody;

  /// No description provided for @threadPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation detail'**
  String get threadPlaceholderTitle;

  /// No description provided for @roomPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice room detail'**
  String get roomPlaceholderTitle;

  /// No description provided for @newChatPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get newChatPlaceholderTitle;

  /// No description provided for @newRoomPlaceholderTitle.
  ///
  /// In en, this message translates to:
  /// **'Create voice room'**
  String get newRoomPlaceholderTitle;

  /// No description provided for @placeholderBody.
  ///
  /// In en, this message translates to:
  /// **'This part of the app is not built yet.'**
  String get placeholderBody;

  /// No description provided for @composeChat.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation'**
  String get composeChat;

  /// No description provided for @composeVoiceRoom.
  ///
  /// In en, this message translates to:
  /// **'Create a voice room'**
  String get composeVoiceRoom;

  /// No description provided for @connectingStatus.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectingStatus;

  /// No description provided for @offlineStatus.
  ///
  /// In en, this message translates to:
  /// **'No connection to server'**
  String get offlineStatus;

  /// No description provided for @returnToVoiceRoom.
  ///
  /// In en, this message translates to:
  /// **'Return to voice room: {roomName}'**
  String returnToVoiceRoom(String roomName);

  /// No description provided for @keyboardNavigationHint.
  ///
  /// In en, this message translates to:
  /// **'Keyboard: Alt+1 Chats, Alt+2 Voice Rooms, Alt+3 Settings'**
  String get keyboardNavigationHint;

  /// No description provided for @routeLabel.
  ///
  /// In en, this message translates to:
  /// **'Route: {route}'**
  String routeLabel(String route);

  /// No description provided for @authLoginTitle.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get authLoginTitle;

  /// No description provided for @authLoginSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account on the provisioned server.'**
  String get authLoginSubtitle;

  /// No description provided for @authRegisterTitle.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get authRegisterTitle;

  /// No description provided for @authRegisterSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a username and password. The owner must activate the account before you can use it.'**
  String get authRegisterSubtitle;

  /// No description provided for @authUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get authUsernameLabel;

  /// No description provided for @authPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordLabel;

  /// No description provided for @authConfirmPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get authConfirmPasswordLabel;

  /// No description provided for @authUsernameHint.
  ///
  /// In en, this message translates to:
  /// **'3–32 lowercase letters, numbers, or underscores'**
  String get authUsernameHint;

  /// No description provided for @authPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'10–256 characters'**
  String get authPasswordHint;

  /// No description provided for @authPasswordPurpose.
  ///
  /// In en, this message translates to:
  /// **'Your password signs you in. It cannot recover your cryptographic identity or message history.'**
  String get authPasswordPurpose;

  /// No description provided for @authLoginAction.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get authLoginAction;

  /// No description provided for @authLoggingInAction.
  ///
  /// In en, this message translates to:
  /// **'Logging in…'**
  String get authLoggingInAction;

  /// No description provided for @authCreateAccountAction.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get authCreateAccountAction;

  /// No description provided for @authCreatingAccountAction.
  ///
  /// In en, this message translates to:
  /// **'Creating account…'**
  String get authCreatingAccountAction;

  /// No description provided for @authSecurityNoticeAction.
  ///
  /// In en, this message translates to:
  /// **'Security & how this app protects you'**
  String get authSecurityNoticeAction;

  /// Title of the single security notice. It is shown as the mandatory last step of device enrollment and again whenever the notice is re-opened from Settings or from the pre-login link.
  ///
  /// In en, this message translates to:
  /// **'What this app protects — and what it doesn\'t'**
  String get securityNoticeTitle;

  /// No description provided for @authBackToLoginAction.
  ///
  /// In en, this message translates to:
  /// **'Back to login'**
  String get authBackToLoginAction;

  /// No description provided for @authBackAction.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get authBackAction;

  /// No description provided for @authUsernameFormatError.
  ///
  /// In en, this message translates to:
  /// **'Use 3–32 letters, numbers, or underscores.'**
  String get authUsernameFormatError;

  /// No description provided for @authPasswordLengthError.
  ///
  /// In en, this message translates to:
  /// **'Password must be between 10 and 256 characters.'**
  String get authPasswordLengthError;

  /// No description provided for @authPasswordsMismatchError.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match.'**
  String get authPasswordsMismatchError;

  /// No description provided for @authInvalidCredentialsMessage.
  ///
  /// In en, this message translates to:
  /// **'Username or password is incorrect.'**
  String get authInvalidCredentialsMessage;

  /// No description provided for @authInactiveAccountMessage.
  ///
  /// In en, this message translates to:
  /// **'This account is waiting for the owner to activate it.'**
  String get authInactiveAccountMessage;

  /// No description provided for @authUsernameTakenMessage.
  ///
  /// In en, this message translates to:
  /// **'That username is already taken.'**
  String get authUsernameTakenMessage;

  /// No description provided for @authRateLimitedMessage.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please wait and try again.'**
  String get authRateLimitedMessage;

  /// No description provided for @authOfflineMessage.
  ///
  /// In en, this message translates to:
  /// **'The provisioned server cannot be reached. Check your connection and try again.'**
  String get authOfflineMessage;

  /// No description provided for @authMalformedResponseMessage.
  ///
  /// In en, this message translates to:
  /// **'The server returned an invalid response. Try again or contact the operator.'**
  String get authMalformedResponseMessage;

  /// No description provided for @authInvalidInputMessage.
  ///
  /// In en, this message translates to:
  /// **'Check the highlighted information and try again.'**
  String get authInvalidInputMessage;

  /// No description provided for @authSessionExpiredMessage.
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Log in again.'**
  String get authSessionExpiredMessage;

  /// No description provided for @authRevokedMessage.
  ///
  /// In en, this message translates to:
  /// **'This session is no longer valid. Local data from this installation was removed.'**
  String get authRevokedMessage;

  /// No description provided for @authStorageUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'Protected storage is unavailable. Fix device storage and try again.'**
  String get authStorageUnavailableMessage;

  /// No description provided for @authGenericErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get authGenericErrorMessage;

  /// No description provided for @authPendingTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting for activation'**
  String get authPendingTitle;

  /// No description provided for @authPendingMessage.
  ///
  /// In en, this message translates to:
  /// **'Your account is waiting for the owner to activate it.'**
  String get authPendingMessage;

  /// No description provided for @authPendingNoPollingMessage.
  ///
  /// In en, this message translates to:
  /// **'There is no automatic activation check. When the owner has activated your account, return to login and enter your password again.'**
  String get authPendingNoPollingMessage;

  /// No description provided for @authCheckAgainAction.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get authCheckAgainAction;

  /// No description provided for @authRestoringSession.
  ///
  /// In en, this message translates to:
  /// **'Restoring your secure session…'**
  String get authRestoringSession;

  /// No description provided for @authSecurityNoticeMessage.
  ///
  /// In en, this message translates to:
  /// **'Your login password authenticates your account. A separate recovery secret protects cryptographic identity material. Neither secret restores message history from the server.'**
  String get authSecurityNoticeMessage;

  /// No description provided for @enrollmentSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Setting up encryption on this device'**
  String get enrollmentSetupTitle;

  /// No description provided for @enrollmentWithheldMessage.
  ///
  /// In en, this message translates to:
  /// **'Finishing secure device setup. Messaging stays unavailable until every security step completes.'**
  String get enrollmentWithheldMessage;

  /// No description provided for @enrollmentRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Your recovery secret'**
  String get enrollmentRecoveryTitle;

  /// No description provided for @enrollmentRecoveryExplanation.
  ///
  /// In en, this message translates to:
  /// **'Save this secret somewhere safe. It restores your account\'s cryptographic identity if your devices are lost. It does not restore messages; the server has no message-history copy.'**
  String get enrollmentRecoveryExplanation;

  /// No description provided for @enrollmentRecoverySeparate.
  ///
  /// In en, this message translates to:
  /// **'This recovery secret is separate from your login password. The server never sees it.'**
  String get enrollmentRecoverySeparate;

  /// No description provided for @enrollmentCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get enrollmentCopyAction;

  /// No description provided for @enrollmentCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Recovery secret copied. The clipboard will be cleared shortly.'**
  String get enrollmentCopiedMessage;

  /// No description provided for @enrollmentSavedCheck.
  ///
  /// In en, this message translates to:
  /// **'I\'ve saved the recovery secret somewhere safe.'**
  String get enrollmentSavedCheck;

  /// No description provided for @enrollmentContinueAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get enrollmentContinueAction;

  /// No description provided for @enrollmentConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm your recovery secret is safe'**
  String get enrollmentConfirmTitle;

  /// No description provided for @enrollmentConfirmCheck.
  ///
  /// In en, this message translates to:
  /// **'Yes, I\'ve stored my recovery secret somewhere safe.'**
  String get enrollmentConfirmCheck;

  /// No description provided for @enrollmentConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm and finish setup'**
  String get enrollmentConfirmAction;

  /// No description provided for @enrollmentBackToSecretAction.
  ///
  /// In en, this message translates to:
  /// **'Back to recovery secret'**
  String get enrollmentBackToSecretAction;

  /// No description provided for @enrollmentRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore cryptographic identity'**
  String get enrollmentRestoreTitle;

  /// No description provided for @enrollmentRestoreExplanation.
  ///
  /// In en, this message translates to:
  /// **'Enter your recovery secret to unlock the encrypted identity backup on this device. Message history is not in this backup.'**
  String get enrollmentRestoreExplanation;

  /// No description provided for @enrollmentRecoverySecretLabel.
  ///
  /// In en, this message translates to:
  /// **'Recovery secret'**
  String get enrollmentRecoverySecretLabel;

  /// No description provided for @enrollmentRestoreAction.
  ///
  /// In en, this message translates to:
  /// **'Restore identity'**
  String get enrollmentRestoreAction;

  /// No description provided for @enrollmentRestoringAction.
  ///
  /// In en, this message translates to:
  /// **'Restoring identity…'**
  String get enrollmentRestoringAction;

  /// No description provided for @enrollmentWrongSecretMessage.
  ///
  /// In en, this message translates to:
  /// **'The recovery secret could not unlock this identity backup. Check it and try again.'**
  String get enrollmentWrongSecretMessage;

  /// No description provided for @enrollmentAmbiguousTitle.
  ///
  /// In en, this message translates to:
  /// **'Registration needs reconciliation'**
  String get enrollmentAmbiguousTitle;

  /// No description provided for @enrollmentAmbiguousMessage.
  ///
  /// In en, this message translates to:
  /// **'The server may have registered this device before the response was lost. The app will not register another device until it can safely reconcile the unsigned device.'**
  String get enrollmentAmbiguousMessage;

  /// No description provided for @enrollmentReconcileAction.
  ///
  /// In en, this message translates to:
  /// **'Reconcile registration'**
  String get enrollmentReconcileAction;

  /// No description provided for @enrollmentDeviceLimitMessage.
  ///
  /// In en, this message translates to:
  /// **'This account has reached its device limit. Remove an old device from an existing installation, then retry.'**
  String get enrollmentDeviceLimitMessage;

  /// No description provided for @enrollmentIdentityRequiredMessage.
  ///
  /// In en, this message translates to:
  /// **'The account identity must be repaired from an existing device before another device can be added.'**
  String get enrollmentIdentityRequiredMessage;

  /// No description provided for @enrollmentBackupMissingMessage.
  ///
  /// In en, this message translates to:
  /// **'No identity backup is available. This device cannot be cross-signed with a recovery secret.'**
  String get enrollmentBackupMissingMessage;

  /// No description provided for @enrollmentStaleVersionMessage.
  ///
  /// In en, this message translates to:
  /// **'A newer identity or backup version exists. Secure setup is blocked to avoid overwriting it.'**
  String get enrollmentStaleVersionMessage;

  /// No description provided for @enrollmentInvalidVectorMessage.
  ///
  /// In en, this message translates to:
  /// **'Security verification failed. This device remains unverified and messaging is unavailable.'**
  String get enrollmentInvalidVectorMessage;

  /// No description provided for @enrollmentLogConflictMessage.
  ///
  /// In en, this message translates to:
  /// **'The signed device log changed concurrently or did not match. Secure setup is blocked.'**
  String get enrollmentLogConflictMessage;

  /// No description provided for @enrollmentUnsupportedMessage.
  ///
  /// In en, this message translates to:
  /// **'This installation does not support the required secure enrollment protocol.'**
  String get enrollmentUnsupportedMessage;

  /// No description provided for @enrollmentGenericMessage.
  ///
  /// In en, this message translates to:
  /// **'Secure setup could not continue. Try again.'**
  String get enrollmentGenericMessage;

  /// No description provided for @enrollmentIdentityRecoveredTitle.
  ///
  /// In en, this message translates to:
  /// **'Identity recovered'**
  String get enrollmentIdentityRecoveredTitle;

  /// No description provided for @enrollmentNoHistoryMessage.
  ///
  /// In en, this message translates to:
  /// **'Your cryptographic identity is ready. No message history was restored: history can only come later from an existing online device, and history transfer is not part of this setup.'**
  String get enrollmentNoHistoryMessage;

  /// No description provided for @enrollmentProtectsHeading.
  ///
  /// In en, this message translates to:
  /// **'What it DOES protect'**
  String get enrollmentProtectsHeading;

  /// The permanent half of the security notice, so it must stay true of every build. It deliberately names no feature: until ADR-052 it read 'messages, files, and voice audio', and the artifact that carried it could not send a file or carry a second of audio (ADR-052).
  ///
  /// In en, this message translates to:
  /// **'Everything you write is encrypted on this phone before it leaves it. The server, anyone watching the network, and anyone who takes the server can see that you are using this app, but not what you wrote.'**
  String get enrollmentProtectsBody;

  /// No description provided for @enrollmentDoesNotProtectHeading.
  ///
  /// In en, this message translates to:
  /// **'What it does NOT protect'**
  String get enrollmentDoesNotProtectHeading;

  /// Rewritten at ADR-052 out of the project's own vocabulary and into the reader's. It previously said 'social graph', 'out of band' and 'compare fingerprints'; the screen it points at is titled Safety number, so a reader could not follow the instruction they were given.
  ///
  /// In en, this message translates to:
  /// **'It does not hide when you connect, from where, how much you send, or who you talk to. Whoever runs the server can see all of that. It cannot tell you that a new contact is really who they say they are until you and they compare the safety number this app shows, in person or over another channel you trust. And it cannot protect messages already open on a phone somebody else has taken or broken into.'**
  String get enrollmentDoesNotProtectBody;

  /// No description provided for @enrollmentUnderstandAction.
  ///
  /// In en, this message translates to:
  /// **'I understand'**
  String get enrollmentUnderstandAction;

  /// Heading of the deployment disclosure section, rendered only by a build that is handed to someone else (ADR-045).
  ///
  /// In en, this message translates to:
  /// **'What this build is'**
  String get disclosureBuildTitle;

  /// No description provided for @disclosureNoIndependentReview.
  ///
  /// In en, this message translates to:
  /// **'Nobody outside the project has reviewed this app\'s encryption. It is written and tested by one person, and a mistake in it would not have been caught.'**
  String get disclosureNoIndependentReview;

  /// No description provided for @disclosureBestEffortDelivery.
  ///
  /// In en, this message translates to:
  /// **'While this app is open, messages arrive as they are sent. While it is closed, your phone looks for new ones on its own schedule — fifteen minutes apart at best, usually far less often, and not at all while it is saving battery, while Data Saver is on and you are using mobile data, if you have not opened the app for several days, or if you have force-stopped it. In Settings you can turn on receiving while closed, which does better on most phones but uses more battery and shows a permanent notice while it is on. Nothing about any of this is guaranteed, so do not rely on it for anything urgent.'**
  String get disclosureBestEffortDelivery;

  /// Added at revision 5 (ADR-052). Every earlier revision described delivery only as slow, which an ordinary reader takes to mean eventual. The server prunes undelivered envelopes on a retention timer it does not publish to clients, so late and never are different outcomes and only one of them was disclosed.
  ///
  /// In en, this message translates to:
  /// **'A message waits on the server only until your phone collects it. After a time set by whoever runs the server, whatever is still waiting is deleted and never arrives, and you will not be told which messages those were. If you go a long time without opening the app, assume you have missed some.'**
  String get disclosureMessagesExpireUnread;

  /// No description provided for @disclosureDeviceOnlyHistory.
  ///
  /// In en, this message translates to:
  /// **'Your messages are stored only on this phone. The server keeps no copy of your history and no backup exists, so uninstalling the app destroys it permanently.'**
  String get disclosureDeviceOnlyHistory;

  /// No description provided for @disclosureRecoveryExcludesHistory.
  ///
  /// In en, this message translates to:
  /// **'Your recovery secret restores your account identity on a new device. It never restores messages; those can only come from another device of yours that still works.'**
  String get disclosureRecoveryExcludesHistory;

  /// No description provided for @disclosureExperimentalGroups.
  ///
  /// In en, this message translates to:
  /// **'Group chats use experimental encryption that is not finished, not standardised, and has not been independently reviewed. An update can reset a group and delete everything in it. On a phone whose processor it has not been tested on, group chats are switched off instead.'**
  String get disclosureExperimentalGroups;

  /// Revision 5 (ADR-052) removed 'search' from this list. Search is built: the chat list filters by name and latest message, and a conversation's own search reads that conversation's whole local history. What was wrong was the claim, not the feature.
  ///
  /// In en, this message translates to:
  /// **'Some things you can see are not built yet: voice rooms and file attachments do nothing, and the display name and photo you choose are not published — other people see the username you registered with.'**
  String get disclosureUnbuiltSurfaces;

  /// No description provided for @disclosureIntendedUse.
  ///
  /// In en, this message translates to:
  /// **'This build is for trying out among people who already trust each other. It is not suitable if your safety depends on your messages staying private.'**
  String get disclosureIntendedUse;

  /// Heading of the one-time re-presentation shown to somebody who accepted an earlier revision of the disclosure (ADR-052). It is a full screen rather than a banner or a notification: the application posts ordinary notifications and a permanent service notice, and habituation to those generalises to warnings that resemble them.
  ///
  /// In en, this message translates to:
  /// **'What this app tells you has changed'**
  String get disclosureChangedTitle;

  /// No description provided for @disclosureChangedLead.
  ///
  /// In en, this message translates to:
  /// **'You accepted an earlier version of the statement below. Some of it was wrong or has changed, so it is being shown again. The parts that are new or different are marked.'**
  String get disclosureChangedLead;

  /// No description provided for @disclosureChangedLabel.
  ///
  /// In en, this message translates to:
  /// **'New or changed'**
  String get disclosureChangedLabel;

  /// No description provided for @contactsNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get contactsNewTitle;

  /// No description provided for @contactsNewGroup.
  ///
  /// In en, this message translates to:
  /// **'New Group'**
  String get contactsNewGroup;

  /// Subtitle on the disabled New Group row when this build has no reachable group stack (ADR-055).
  ///
  /// In en, this message translates to:
  /// **'Not available on this device'**
  String get contactsNewGroupClosed;

  /// No description provided for @contactsNewVoiceRoom.
  ///
  /// In en, this message translates to:
  /// **'New Voice Room'**
  String get contactsNewVoiceRoom;

  /// No description provided for @contactsSearchLabel.
  ///
  /// In en, this message translates to:
  /// **'Search contacts'**
  String get contactsSearchLabel;

  /// No description provided for @contactsLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Loading contacts'**
  String get contactsLoadingTitle;

  /// No description provided for @contactsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No contacts yet'**
  String get contactsEmptyTitle;

  /// No description provided for @contactsEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Activated users will appear here after the directory refreshes.'**
  String get contactsEmptyMessage;

  /// No description provided for @contactsOfflineMessage.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing cached contacts'**
  String get contactsOfflineMessage;

  /// No description provided for @contactsLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more contacts'**
  String get contactsLoadMore;

  /// No description provided for @contactsVerified.
  ///
  /// In en, this message translates to:
  /// **'Identity verified'**
  String get contactsVerified;

  /// No description provided for @contactsUnverified.
  ///
  /// In en, this message translates to:
  /// **'Identity not verified'**
  String get contactsUnverified;

  /// No description provided for @contactsUsernameFallback.
  ///
  /// In en, this message translates to:
  /// **'Backend username shown until the encrypted profile and identity are authenticated.'**
  String get contactsUsernameFallback;

  /// No description provided for @contactProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'Contact profile'**
  String get contactProfileTitle;

  /// No description provided for @contactMessageAction.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get contactMessageAction;

  /// No description provided for @contactMuteAction.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get contactMuteAction;

  /// No description provided for @contactVerifyAction.
  ///
  /// In en, this message translates to:
  /// **'Verify safety number'**
  String get contactVerifyAction;

  /// No description provided for @contactSharedMediaAction.
  ///
  /// In en, this message translates to:
  /// **'Shared media and files'**
  String get contactSharedMediaAction;

  /// No description provided for @contactClearHistoryAction.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get contactClearHistoryAction;

  /// No description provided for @contactBlockAction.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get contactBlockAction;

  /// No description provided for @contactSensitiveBlocked.
  ///
  /// In en, this message translates to:
  /// **'Messaging is withheld until this identity and every device pass verification.'**
  String get contactSensitiveBlocked;

  /// No description provided for @profileEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get profileEditTitle;

  /// No description provided for @profileDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get profileDisplayNameLabel;

  /// No description provided for @profileVisibilityNote.
  ///
  /// In en, this message translates to:
  /// **'This encrypted profile is visible only to contacts who receive an authenticated profile key. Keep personal information minimal.'**
  String get profileVisibilityNote;

  /// No description provided for @profileAvatarStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Avatar style'**
  String get profileAvatarStyleLabel;

  /// No description provided for @profileSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save encrypted profile'**
  String get profileSaveAction;

  /// No description provided for @profileSavingAction.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get profileSavingAction;

  /// No description provided for @profileTemporaryTransport.
  ///
  /// In en, this message translates to:
  /// **'Development build only: profile encryption and key delivery here are a stand-in, not real cryptography.'**
  String get profileTemporaryTransport;

  /// No description provided for @profileNotBuiltNotice.
  ///
  /// In en, this message translates to:
  /// **'This build cannot publish a profile yet. The name and photo you choose here are not sent anywhere, and your contacts see the username you registered with.'**
  String get profileNotBuiltNotice;

  /// No description provided for @profileSavedMessage.
  ///
  /// In en, this message translates to:
  /// **'Encrypted profile published.'**
  String get profileSavedMessage;

  /// No description provided for @profileInvalidName.
  ///
  /// In en, this message translates to:
  /// **'Enter a display name of 1 to 64 characters.'**
  String get profileInvalidName;

  /// No description provided for @safetyTitle.
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get safetyTitle;

  /// No description provided for @safetyInstructions.
  ///
  /// In en, this message translates to:
  /// **'Compare these values in person or over another trusted channel. The server cannot confirm them for you.'**
  String get safetyInstructions;

  /// No description provided for @safetyEmojiLabel.
  ///
  /// In en, this message translates to:
  /// **'Emoji comparison'**
  String get safetyEmojiLabel;

  /// No description provided for @safetyNumberLabel.
  ///
  /// In en, this message translates to:
  /// **'Number comparison'**
  String get safetyNumberLabel;

  /// No description provided for @safetyQrLabel.
  ///
  /// In en, this message translates to:
  /// **'QR safety value'**
  String get safetyQrLabel;

  /// No description provided for @safetyOutOfBandCheck.
  ///
  /// In en, this message translates to:
  /// **'I compared the values out of band with this contact.'**
  String get safetyOutOfBandCheck;

  /// No description provided for @safetyConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm verified'**
  String get safetyConfirmAction;

  /// No description provided for @safetyVerifiedState.
  ///
  /// In en, this message translates to:
  /// **'Verified — the exact master key is attested by your user-signing key.'**
  String get safetyVerifiedState;

  /// No description provided for @safetyUnverifiedState.
  ///
  /// In en, this message translates to:
  /// **'Unverified — messaging withheld'**
  String get safetyUnverifiedState;

  /// No description provided for @safetyMasterChangedState.
  ///
  /// In en, this message translates to:
  /// **'Master key changed — sensitive actions are blocked until you verify the new values out of band.'**
  String get safetyMasterChangedState;

  /// No description provided for @safetyInvalidDeviceState.
  ///
  /// In en, this message translates to:
  /// **'Unsigned or invalid device — messages are withheld.'**
  String get safetyInvalidDeviceState;

  /// No description provided for @safetyForkState.
  ///
  /// In en, this message translates to:
  /// **'Device-log fork detected — all sensitive actions are blocked.'**
  String get safetyForkState;

  /// No description provided for @safetyIdentityUnavailableState.
  ///
  /// In en, this message translates to:
  /// **'A valid signed identity is unavailable.'**
  String get safetyIdentityUnavailableState;

  /// No description provided for @safetyRefreshing.
  ///
  /// In en, this message translates to:
  /// **'Verifying identity, devices, prekeys, and device log…'**
  String get safetyRefreshing;

  /// No description provided for @safetyRetryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry verification'**
  String get safetyRetryAction;

  /// No description provided for @safetyConfirmationRequired.
  ///
  /// In en, this message translates to:
  /// **'Out-of-band comparison is required before confirmation.'**
  String get safetyConfirmationRequired;

  /// No description provided for @chatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @chatsSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Search chats'**
  String get chatsSearchAction;

  /// No description provided for @chatsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search names and the latest message'**
  String get chatsSearchHint;

  /// No description provided for @chatsClearSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get chatsClearSearchAction;

  /// No description provided for @chatsLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Loading chats'**
  String get chatsLoadingTitle;

  /// No description provided for @chatsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats are unavailable'**
  String get chatsErrorTitle;

  /// No description provided for @chatsErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'The encrypted local conversation list could not be opened.'**
  String get chatsErrorMessage;

  /// No description provided for @chatsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get chatsEmptyTitle;

  /// No description provided for @chatsEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Start a verified direct message. Conversations will remain readable offline on this device.'**
  String get chatsEmptyMessage;

  /// No description provided for @chatsStartAction.
  ///
  /// In en, this message translates to:
  /// **'Start a chat'**
  String get chatsStartAction;

  /// No description provided for @chatsNoSearchResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing found on this phone'**
  String get chatsNoSearchResultsTitle;

  /// No description provided for @chatsDeviceSearchScopeNotice.
  ///
  /// In en, this message translates to:
  /// **'This searches only the messages stored on this phone. The server never sees them, or what you search for.'**
  String get chatsDeviceSearchScopeNotice;

  /// The chat list filters on title and last-message preview and nothing else. Before ADR-052 it borrowed the in-conversation notice, which promised a search of this device's history that the list has never performed.
  ///
  /// In en, this message translates to:
  /// **'This list matches names and the latest message only. To search a conversation\'s history, open it and search inside.'**
  String get chatsListSearchScopeNotice;

  /// No description provided for @chatsDeliveryConnectingNotice.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get chatsDeliveryConnectingNotice;

  /// No description provided for @chatsDeliverySyncingNotice.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get chatsDeliverySyncingNotice;

  /// No description provided for @chatsDeliveryWaitingNotice.
  ///
  /// In en, this message translates to:
  /// **'Waiting to reconnect…'**
  String get chatsDeliveryWaitingNotice;

  /// No description provided for @chatsOfflineCachedNotice.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing cached conversations. New messages will queue locally.'**
  String get chatsOfflineCachedNotice;

  /// No description provided for @chatsNoMessagesPreview.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get chatsNoMessagesPreview;

  /// No description provided for @chatsConversationActionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Conversation actions'**
  String get chatsConversationActionsLabel;

  /// No description provided for @chatsMuteAction.
  ///
  /// In en, this message translates to:
  /// **'Mute for 8 hours'**
  String get chatsMuteAction;

  /// No description provided for @chatsUnmuteAction.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get chatsUnmuteAction;

  /// No description provided for @chatsMarkReadAction.
  ///
  /// In en, this message translates to:
  /// **'Mark as read'**
  String get chatsMarkReadAction;

  /// No description provided for @chatsMarkUnreadAction.
  ///
  /// In en, this message translates to:
  /// **'Mark as unread'**
  String get chatsMarkUnreadAction;

  /// No description provided for @chatsDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get chatsDeleteAction;

  /// No description provided for @chatsDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this chat?'**
  String get chatsDeleteTitle;

  /// No description provided for @chatsDeleteLocalOnlyMessage.
  ///
  /// In en, this message translates to:
  /// **'Clearing a chat removes this device\'s local view only. It does not delete content already received by other devices.'**
  String get chatsDeleteLocalOnlyMessage;

  /// No description provided for @chatsItemSemantics.
  ///
  /// In en, this message translates to:
  /// **'{title}. {preview}. {unreadCount} unread messages.'**
  String chatsItemSemantics(String title, String preview, int unreadCount);

  /// No description provided for @chatTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get chatTitle;

  /// No description provided for @savedMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Saved Messages'**
  String get savedMessagesTitle;

  /// No description provided for @savedMessagesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing saved yet'**
  String get savedMessagesEmptyTitle;

  /// No description provided for @savedMessagesEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Messages here are local to your encrypted self-conversation and never show peer presence or receipts.'**
  String get savedMessagesEmptyMessage;

  /// No description provided for @savedMessagesComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Write a note to yourself'**
  String get savedMessagesComposerHint;

  /// No description provided for @chatHistoryLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading encrypted history'**
  String get chatHistoryLoading;

  /// No description provided for @chatHistoryErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'History is unavailable'**
  String get chatHistoryErrorTitle;

  /// No description provided for @chatHistoryErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'The encrypted local history could not be read. No server copy exists.'**
  String get chatHistoryErrorMessage;

  /// No description provided for @chatEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Start the conversation'**
  String get chatEmptyTitle;

  /// No description provided for @chatEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Messages are encrypted on this device before they enter the delivery queue.'**
  String get chatEmptyMessage;

  /// No description provided for @chatTimelineSemantics.
  ///
  /// In en, this message translates to:
  /// **'Message timeline for {title}'**
  String chatTimelineSemantics(String title);

  /// No description provided for @chatMessageSemantics.
  ///
  /// In en, this message translates to:
  /// **'{author}: {message}. State: {state}.'**
  String chatMessageSemantics(String author, String message, String state);

  /// No description provided for @chatMessageActionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Message actions'**
  String get chatMessageActionsLabel;

  /// No description provided for @chatReplyAction.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get chatReplyAction;

  /// No description provided for @chatEditAction.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatEditAction;

  /// No description provided for @chatForwardAction.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get chatForwardAction;

  /// No description provided for @chatCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatCopyAction;

  /// No description provided for @chatStarAction.
  ///
  /// In en, this message translates to:
  /// **'Star on this device'**
  String get chatStarAction;

  /// No description provided for @chatUnstarAction.
  ///
  /// In en, this message translates to:
  /// **'Remove star'**
  String get chatUnstarAction;

  /// No description provided for @chatPinAction.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get chatPinAction;

  /// No description provided for @chatUnpinAction.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get chatUnpinAction;

  /// No description provided for @chatDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDeleteAction;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteHonestMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete for me removes this device\'s local copy. Delete for everyone is best-effort and cannot force another device to forget content it already received and decrypted.'**
  String get chatDeleteHonestMessage;

  /// No description provided for @chatDeleteForMeAction.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get chatDeleteForMeAction;

  /// No description provided for @chatDeleteForEveryoneAction.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get chatDeleteForEveryoneAction;

  /// No description provided for @chatCancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatCancelAction;

  /// No description provided for @chatDeletedMessage.
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get chatDeletedMessage;

  /// No description provided for @chatUnsupportedMessage.
  ///
  /// In en, this message translates to:
  /// **'This message needs a newer supported protocol. Its encrypted record was retained.'**
  String get chatUnsupportedMessage;

  /// No description provided for @chatSystemMessage.
  ///
  /// In en, this message translates to:
  /// **'Conversation update'**
  String get chatSystemMessage;

  /// No description provided for @chatEditedLabel.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get chatEditedLabel;

  /// No description provided for @chatTimestampSkewed.
  ///
  /// In en, this message translates to:
  /// **'The sender\'s clock appears inaccurate; this time is display-only.'**
  String get chatTimestampSkewed;

  /// No description provided for @chatReplyQuote.
  ///
  /// In en, this message translates to:
  /// **'Replied message'**
  String get chatReplyQuote;

  /// No description provided for @chatReactionSemantics.
  ///
  /// In en, this message translates to:
  /// **'{emoji} reaction, {count} people'**
  String chatReactionSemantics(String emoji, int count);

  /// Accessible name of the floating reaction selector that opens with the message actions. It names the surface, not the message, because the message already has its own label.
  ///
  /// In en, this message translates to:
  /// **'Choose a reaction'**
  String get chatReactionSelectorLabel;

  /// Accessible name of one emoji in the reaction selector, when it is not the reaction this user has set.
  ///
  /// In en, this message translates to:
  /// **'React with {emoji}'**
  String chatReactionAddAction(String emoji);

  /// Accessible name of the emoji in the reaction selector that this user has already set. Choosing it removes the reaction, so the label has to say so rather than repeating the add wording.
  ///
  /// In en, this message translates to:
  /// **'Remove your {emoji} reaction'**
  String chatReactionRemoveAction(String emoji);

  /// The control at the end of the reaction selector that opens the full emoji picker.
  ///
  /// In en, this message translates to:
  /// **'More emoji'**
  String get chatMoreReactionsAction;

  /// No description provided for @chatRetrySendAction.
  ///
  /// In en, this message translates to:
  /// **'Retry as a new encrypted send'**
  String get chatRetrySendAction;

  /// No description provided for @chatUnreadDivider.
  ///
  /// In en, this message translates to:
  /// **'Unread messages'**
  String get chatUnreadDivider;

  /// No description provided for @chatLoadingOlder.
  ///
  /// In en, this message translates to:
  /// **'Loading older messages'**
  String get chatLoadingOlder;

  /// No description provided for @chatLoadOlderAction.
  ///
  /// In en, this message translates to:
  /// **'Load older messages'**
  String get chatLoadOlderAction;

  /// No description provided for @chatOlderErrorAction.
  ///
  /// In en, this message translates to:
  /// **'Older messages could not load — retry'**
  String get chatOlderErrorAction;

  /// No description provided for @chatBeginningOfHistory.
  ///
  /// In en, this message translates to:
  /// **'Beginning of local history'**
  String get chatBeginningOfHistory;

  /// No description provided for @chatJumpToLatestAction.
  ///
  /// In en, this message translates to:
  /// **'Jump to latest message'**
  String get chatJumpToLatestAction;

  /// No description provided for @chatComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatComposerHint;

  /// No description provided for @chatAttachAction.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get chatAttachAction;

  /// No description provided for @chatEmojiAction.
  ///
  /// In en, this message translates to:
  /// **'Insert emoji'**
  String get chatEmojiAction;

  /// Accessible name of the composer's emoji button while the inline emoji panel is open. Pressing it hides the panel and returns the soft keyboard, so the label names what the press does rather than what the panel is.
  ///
  /// In en, this message translates to:
  /// **'Close emoji panel'**
  String get chatEmojiPanelCloseAction;

  /// Accessible name of the full emoji picker surface (ADR-059). It is opened both from the composer and from the reaction selector, so the wording names the surface rather than either caller.
  ///
  /// In en, this message translates to:
  /// **'Emoji picker'**
  String get emojiPickerLabel;

  /// Placeholder in the emoji picker's search field. The search runs over the locally bundled emoji names only; nothing is sent anywhere.
  ///
  /// In en, this message translates to:
  /// **'Search emoji'**
  String get emojiPickerSearchHint;

  /// No description provided for @chatSendAction.
  ///
  /// In en, this message translates to:
  /// **'Send encrypted message'**
  String get chatSendAction;

  /// No description provided for @chatSaveEditAction.
  ///
  /// In en, this message translates to:
  /// **'Save encrypted edit'**
  String get chatSaveEditAction;

  /// No description provided for @chatCancelContextAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply or edit'**
  String get chatCancelContextAction;

  /// No description provided for @chatEditingMessage.
  ///
  /// In en, this message translates to:
  /// **'Editing message'**
  String get chatEditingMessage;

  /// No description provided for @chatReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to {author}'**
  String chatReplyingTo(String author);

  /// No description provided for @chatOfflineQueueNotice.
  ///
  /// In en, this message translates to:
  /// **'Offline — sending stores encrypted queue work locally until this server is reachable.'**
  String get chatOfflineQueueNotice;

  /// No description provided for @chatWithheldUnverifiedIdentity.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: verify this identity out of band before sending.'**
  String get chatWithheldUnverifiedIdentity;

  /// No description provided for @chatWithheldUnverifiedDevice.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: an unsigned or invalid device cannot receive messages.'**
  String get chatWithheldUnverifiedDevice;

  /// No description provided for @chatWithheldMasterChanged.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: the contact\'s master key changed and must be verified again.'**
  String get chatWithheldMasterChanged;

  /// No description provided for @chatWithheldLogFork.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: a device-log fork indicates possible server equivocation.'**
  String get chatWithheldLogFork;

  /// No description provided for @chatWithheldPq.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: required ML-KEM post-quantum key material is unavailable. The app will not downgrade.'**
  String get chatWithheldPq;

  /// No description provided for @chatPinnedBanner.
  ///
  /// In en, this message translates to:
  /// **'{count} pinned messages'**
  String chatPinnedBanner(int count);

  /// No description provided for @chatPinnedExpandAction.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get chatPinnedExpandAction;

  /// No description provided for @chatPinnedMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned messages'**
  String get chatPinnedMessagesTitle;

  /// No description provided for @chatTypingStatus.
  ///
  /// In en, this message translates to:
  /// **'typing… encrypted signal may lag'**
  String get chatTypingStatus;

  /// No description provided for @chatSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Search in chat'**
  String get chatSearchAction;

  /// No description provided for @chatSearchInputLabel.
  ///
  /// In en, this message translates to:
  /// **'Search local messages'**
  String get chatSearchInputLabel;

  /// No description provided for @chatSearchEmptyQueryTitle.
  ///
  /// In en, this message translates to:
  /// **'Search this device\'s history'**
  String get chatSearchEmptyQueryTitle;

  /// No description provided for @chatMoreAction.
  ///
  /// In en, this message translates to:
  /// **'More conversation actions'**
  String get chatMoreAction;

  /// No description provided for @chatYouAuthor.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get chatYouAuthor;

  /// No description provided for @chatAttachmentsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Open or save verified file'**
  String get chatAttachmentsUnavailable;

  /// No description provided for @attachmentChoosePrompt.
  ///
  /// In en, this message translates to:
  /// **'Choose encrypted media or a file.'**
  String get attachmentChoosePrompt;

  /// No description provided for @attachmentsNotBuiltNotice.
  ///
  /// In en, this message translates to:
  /// **'File attachments are not built yet. Nothing can be attached to a message in this build.'**
  String get attachmentsNotBuiltNotice;

  /// No description provided for @attachmentPhotoOption.
  ///
  /// In en, this message translates to:
  /// **'Photo or image'**
  String get attachmentPhotoOption;

  /// No description provided for @attachmentFileOption.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get attachmentFileOption;

  /// No description provided for @attachmentCameraOption.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get attachmentCameraOption;

  /// No description provided for @attachmentImageLabel.
  ///
  /// In en, this message translates to:
  /// **'Encrypted image'**
  String get attachmentImageLabel;

  /// No description provided for @attachmentFileLabel.
  ///
  /// In en, this message translates to:
  /// **'Encrypted attachment'**
  String get attachmentFileLabel;

  /// No description provided for @attachmentOpenHint.
  ///
  /// In en, this message translates to:
  /// **'Open after local verification'**
  String get attachmentOpenHint;

  /// No description provided for @attachmentQueuedState.
  ///
  /// In en, this message translates to:
  /// **'attachment queued'**
  String get attachmentQueuedState;

  /// No description provided for @attachmentDownloadingState.
  ///
  /// In en, this message translates to:
  /// **'downloading attachment'**
  String get attachmentDownloadingState;

  /// No description provided for @attachmentVerifyingState.
  ///
  /// In en, this message translates to:
  /// **'verifying attachment'**
  String get attachmentVerifyingState;

  /// No description provided for @attachmentReadyState.
  ///
  /// In en, this message translates to:
  /// **'verified attachment'**
  String get attachmentReadyState;

  /// No description provided for @attachmentExpiredState.
  ///
  /// In en, this message translates to:
  /// **'attachment expired'**
  String get attachmentExpiredState;

  /// No description provided for @attachmentCancelledState.
  ///
  /// In en, this message translates to:
  /// **'attachment cancelled'**
  String get attachmentCancelledState;

  /// No description provided for @attachmentQuotaState.
  ///
  /// In en, this message translates to:
  /// **'attachment quota exceeded'**
  String get attachmentQuotaState;

  /// No description provided for @attachmentUnsupportedState.
  ///
  /// In en, this message translates to:
  /// **'attachment unsupported'**
  String get attachmentUnsupportedState;

  /// No description provided for @attachmentCorruptState.
  ///
  /// In en, this message translates to:
  /// **'attachment corrupt'**
  String get attachmentCorruptState;

  /// No description provided for @attachmentFailedState.
  ///
  /// In en, this message translates to:
  /// **'attachment failed'**
  String get attachmentFailedState;

  /// No description provided for @attachmentDetails.
  ///
  /// In en, this message translates to:
  /// **'{mimeType} · {size} bytes'**
  String attachmentDetails(String mimeType, int size);

  /// No description provided for @chatActionFailedMessage.
  ///
  /// In en, this message translates to:
  /// **'That action could not be completed. No security guarantee was weakened.'**
  String get chatActionFailedMessage;

  /// No description provided for @chatStateLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'saved locally only'**
  String get chatStateLocalOnly;

  /// No description provided for @chatStateQueued.
  ///
  /// In en, this message translates to:
  /// **'queued offline'**
  String get chatStateQueued;

  /// No description provided for @chatStateEncrypting.
  ///
  /// In en, this message translates to:
  /// **'encrypting'**
  String get chatStateEncrypting;

  /// No description provided for @chatStateSending.
  ///
  /// In en, this message translates to:
  /// **'sending to server'**
  String get chatStateSending;

  /// No description provided for @chatStateAccepted.
  ///
  /// In en, this message translates to:
  /// **'accepted by server relay'**
  String get chatStateAccepted;

  /// No description provided for @chatStateDelivered.
  ///
  /// In en, this message translates to:
  /// **'durably delivered to a recipient device'**
  String get chatStateDelivered;

  /// No description provided for @chatStateRead.
  ///
  /// In en, this message translates to:
  /// **'read receipt received'**
  String get chatStateRead;

  /// No description provided for @chatStateFailed.
  ///
  /// In en, this message translates to:
  /// **'send failed'**
  String get chatStateFailed;

  /// No description provided for @chatStateReceived.
  ///
  /// In en, this message translates to:
  /// **'received'**
  String get chatStateReceived;

  /// No description provided for @groupProductionUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Production groups are not available'**
  String get groupProductionUnavailableTitle;

  /// No description provided for @groupProductionUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'The post-quantum MLS profile is still gated. This build cannot create groups, generate KeyPackages, or send group ciphertext.'**
  String get groupProductionUnavailableMessage;

  /// Title of the closed gate in the private experimental build, where the group stack exists but is withheld for want of on-device evidence (ADR-055).
  ///
  /// In en, this message translates to:
  /// **'Group messaging is not available on this device'**
  String get groupExperimentalWithheldTitle;

  /// Explains that the group surface is withheld pending measurement, that it is off in substance rather than hidden, and that direct messages still work.
  ///
  /// In en, this message translates to:
  /// **'The experimental group encryption has been tested on 64-bit ARM phones, and this device uses a different processor. Rather than run it untested, group chats are switched off here: no keys are published for you and no group message can reach this device. Direct messages are unaffected.'**
  String get groupExperimentalWithheldMessage;

  /// Shown on group screens in a development build, where the in-memory fake never transmits anything.
  ///
  /// In en, this message translates to:
  /// **'Development preview only — no production group ciphertext is sent'**
  String get groupDevelopmentPreviewBanner;

  /// Shown on group screens in the private experimental build. Group objects really are transmitted here, and the state they produce is disposable by decision, so the wording must not reuse the development preview's promise that nothing is sent.
  ///
  /// In en, this message translates to:
  /// **'Experimental group encryption — not reviewed or standardized. An update may reset these groups and delete their messages.'**
  String get groupExperimentalBanner;

  /// No description provided for @groupCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Group'**
  String get groupCreateTitle;

  /// No description provided for @groupPickMembersTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick members'**
  String get groupPickMembersTitle;

  /// No description provided for @groupDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Group details'**
  String get groupDetailsTitle;

  /// No description provided for @groupNextAction.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get groupNextAction;

  /// No description provided for @groupBackAction.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get groupBackAction;

  /// No description provided for @groupCreateAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get groupCreateAction;

  /// No description provided for @groupCreatingState.
  ///
  /// In en, this message translates to:
  /// **'Creating local group preview…'**
  String get groupCreatingState;

  /// No description provided for @groupCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'The group could not be created. Nothing was sent.'**
  String get groupCreateFailed;

  /// No description provided for @groupSelectMemberMessage.
  ///
  /// In en, this message translates to:
  /// **'Select at least one member.'**
  String get groupSelectMemberMessage;

  /// No description provided for @groupMemberLimitMessage.
  ///
  /// In en, this message translates to:
  /// **'A group can have at most 50 members, including you.'**
  String get groupMemberLimitMessage;

  /// No description provided for @groupNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameLabel;

  /// No description provided for @groupDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get groupDescriptionLabel;

  /// No description provided for @groupPhotoAction.
  ///
  /// In en, this message translates to:
  /// **'Choose encrypted photo'**
  String get groupPhotoAction;

  /// No description provided for @groupPhotoSelected.
  ///
  /// In en, this message translates to:
  /// **'A local preview photo is selected'**
  String get groupPhotoSelected;

  /// No description provided for @groupSearchMembersLabel.
  ///
  /// In en, this message translates to:
  /// **'Search members'**
  String get groupSearchMembersLabel;

  /// No description provided for @groupSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String groupSelectedCount(int count);

  /// No description provided for @groupMemberCount.
  ///
  /// In en, this message translates to:
  /// **'{count} members'**
  String groupMemberCount(int count);

  /// No description provided for @groupInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Group Info'**
  String get groupInfoTitle;

  /// No description provided for @groupEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Group'**
  String get groupEditTitle;

  /// No description provided for @groupEditAction.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get groupEditAction;

  /// No description provided for @groupAddMembersAction.
  ///
  /// In en, this message translates to:
  /// **'Add members'**
  String get groupAddMembersAction;

  /// No description provided for @groupLeaveAction.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get groupLeaveAction;

  /// No description provided for @groupRemoveAction.
  ///
  /// In en, this message translates to:
  /// **'Remove from group'**
  String get groupRemoveAction;

  /// No description provided for @groupPromoteAction.
  ///
  /// In en, this message translates to:
  /// **'Make admin'**
  String get groupPromoteAction;

  /// No description provided for @groupDemoteAction.
  ///
  /// In en, this message translates to:
  /// **'Make member'**
  String get groupDemoteAction;

  /// No description provided for @groupTransferOwnerAction.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership'**
  String get groupTransferOwnerAction;

  /// No description provided for @groupRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get groupRoleOwner;

  /// No description provided for @groupRoleAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get groupRoleAdmin;

  /// No description provided for @groupRoleMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get groupRoleMember;

  /// No description provided for @groupInvitePolicyLabel.
  ///
  /// In en, this message translates to:
  /// **'Who can add members'**
  String get groupInvitePolicyLabel;

  /// No description provided for @groupInviteOwnerOnly.
  ///
  /// In en, this message translates to:
  /// **'Owner only'**
  String get groupInviteOwnerOnly;

  /// No description provided for @groupInviteAdmins.
  ///
  /// In en, this message translates to:
  /// **'Owner and admins'**
  String get groupInviteAdmins;

  /// No description provided for @groupInviteEveryone.
  ///
  /// In en, this message translates to:
  /// **'All members'**
  String get groupInviteEveryone;

  /// No description provided for @groupHistorySharingLabel.
  ///
  /// In en, this message translates to:
  /// **'Show available past history to new members'**
  String get groupHistorySharingLabel;

  /// No description provided for @groupHistorySharingNote.
  ///
  /// In en, this message translates to:
  /// **'When this is on, an existing member’s device intentionally re-shares the backlog to the newcomer. The server cannot reconstruct or send that history, and the source device may have only partial history.'**
  String get groupHistorySharingNote;

  /// No description provided for @groupSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get groupSaveAction;

  /// No description provided for @groupCancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get groupCancelAction;

  /// No description provided for @groupPermissionChanged.
  ///
  /// In en, this message translates to:
  /// **'Your role changed. These settings can no longer be saved.'**
  String get groupPermissionChanged;

  /// No description provided for @groupMembershipUpdatingState.
  ///
  /// In en, this message translates to:
  /// **'Membership is updating. Sending and member changes are paused.'**
  String get groupMembershipUpdatingState;

  /// No description provided for @groupRemovedState.
  ///
  /// In en, this message translates to:
  /// **'You were removed. Past content on this device stays readable, but future group epochs are unavailable.'**
  String get groupRemovedState;

  /// No description provided for @groupLeftState.
  ///
  /// In en, this message translates to:
  /// **'You left this group. This copy is read-only.'**
  String get groupLeftState;

  /// No description provided for @groupQueueGapState.
  ///
  /// In en, this message translates to:
  /// **'A mailbox gap may have hidden an MLS commit. This device must be removed and re-added with a fresh Welcome before sending.'**
  String get groupQueueGapState;

  /// No description provided for @groupForkState.
  ///
  /// In en, this message translates to:
  /// **'Concurrent MLS commits were quarantined. The client will not choose a branch.'**
  String get groupForkState;

  /// No description provided for @groupControlQuarantineState.
  ///
  /// In en, this message translates to:
  /// **'An invalid or unauthorized group control was quarantined.'**
  String get groupControlQuarantineState;

  /// No description provided for @groupReadOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Read-only group'**
  String get groupReadOnlyLabel;

  /// No description provided for @groupMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message group'**
  String get groupMessageHint;

  /// No description provided for @groupSendFailed.
  ///
  /// In en, this message translates to:
  /// **'The message was not saved. Nothing was sent.'**
  String get groupSendFailed;

  /// No description provided for @groupMuteAction.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get groupMuteAction;

  /// No description provided for @groupSearchChatAction.
  ///
  /// In en, this message translates to:
  /// **'Search in chat'**
  String get groupSearchChatAction;

  /// No description provided for @groupSharedMediaAction.
  ///
  /// In en, this message translates to:
  /// **'Shared media'**
  String get groupSharedMediaAction;

  /// No description provided for @groupNoDescription.
  ///
  /// In en, this message translates to:
  /// **'No description'**
  String get groupNoDescription;

  /// No description provided for @groupMembersSection.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupMembersSection;

  /// No description provided for @groupVerifiedMember.
  ///
  /// In en, this message translates to:
  /// **'Verified identity'**
  String get groupVerifiedMember;

  /// No description provided for @groupConfirmRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove member?'**
  String get groupConfirmRemoveTitle;

  /// No description provided for @groupConfirmRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'Removing this member advances the group epoch and cuts off access to future messages. It cannot erase content already received.'**
  String get groupConfirmRemoveBody;

  /// No description provided for @groupConfirmLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave group?'**
  String get groupConfirmLeaveTitle;

  /// No description provided for @groupConfirmLeaveBody.
  ///
  /// In en, this message translates to:
  /// **'You will lose access to future group epochs. Content already stored on this device remains readable.'**
  String get groupConfirmLeaveBody;

  /// No description provided for @groupOwnerMustTransfer.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership before leaving this group.'**
  String get groupOwnerMustTransfer;

  /// No description provided for @groupActionFailed.
  ///
  /// In en, this message translates to:
  /// **'That group change could not be committed. The previous group state is unchanged.'**
  String get groupActionFailed;

  /// No description provided for @groupMemberPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No eligible contacts found'**
  String get groupMemberPickerEmpty;

  /// No description provided for @groupWithheldUpdating.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: membership is updating.'**
  String get groupWithheldUpdating;

  /// No description provided for @groupWithheldRemoved.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: this group is read-only on this device.'**
  String get groupWithheldRemoved;

  /// No description provided for @groupWithheldQueueGap.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: rejoin with a fresh Welcome after the mailbox gap.'**
  String get groupWithheldQueueGap;

  /// No description provided for @groupWithheldConflict.
  ///
  /// In en, this message translates to:
  /// **'Messaging withheld: a group control conflict is quarantined.'**
  String get groupWithheldConflict;

  /// The whole content of the permanent entry the foreground service displays. It names nothing, counts nothing and promises nothing; the screen that turns the capability on is where its limits are stated.
  ///
  /// In en, this message translates to:
  /// **'Kept open in the background'**
  String get sustainedNotificationTitle;

  /// Names the notification category in Android system settings for this app. The user adjusts it there, so the name has to be recognisable out of context.
  ///
  /// In en, this message translates to:
  /// **'Running in the background'**
  String get sustainedChannelName;

  /// No description provided for @sustainedChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Shown while the app is kept open so that messages can arrive.'**
  String get sustainedChannelDescription;

  /// No description provided for @settingsSustainedTitle.
  ///
  /// In en, this message translates to:
  /// **'Receiving while closed'**
  String get settingsSustainedTitle;

  /// No description provided for @settingsSustainedOff.
  ///
  /// In en, this message translates to:
  /// **'Off. Your phone looks for messages on its own schedule, which is slow and often not at all.'**
  String get settingsSustainedOff;

  /// No description provided for @settingsSustainedHolding.
  ///
  /// In en, this message translates to:
  /// **'On. The app is kept open in the background, and there is a permanent notice on your phone while it is.'**
  String get settingsSustainedHolding;

  /// No description provided for @settingsSustainedAlertsWithheld.
  ///
  /// In en, this message translates to:
  /// **'On, but notifications are switched off, so nothing would tell you a message arrived.'**
  String get settingsSustainedAlertsWithheld;

  /// No description provided for @settingsSustainedExemptionWithdrawn.
  ///
  /// In en, this message translates to:
  /// **'On, but your phone has taken back permission to run while it saves battery.'**
  String get settingsSustainedExemptionWithdrawn;

  /// No description provided for @settingsSustainedStopped.
  ///
  /// In en, this message translates to:
  /// **'On, but it is not running right now.'**
  String get settingsSustainedStopped;

  /// No description provided for @settingsSustainedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available in this build.'**
  String get settingsSustainedUnavailable;

  /// No description provided for @settingsSustainedWithheld.
  ///
  /// In en, this message translates to:
  /// **'Not offered in this build. It has not been tested on phones like yours yet.'**
  String get settingsSustainedWithheld;

  /// No description provided for @sustainedTitle.
  ///
  /// In en, this message translates to:
  /// **'Receiving while closed'**
  String get sustainedTitle;

  /// No description provided for @sustainedWhatItDoes.
  ///
  /// In en, this message translates to:
  /// **'Normally your phone stops this app when you leave it, and only lets it look for new messages every fifteen minutes at best. Turned on, the app is kept open in the background instead, so a message can reach you without waiting for that. How quickly it does on your phone has not been measured.'**
  String get sustainedWhatItDoes;

  /// No description provided for @sustainedWhatItCosts.
  ///
  /// In en, this message translates to:
  /// **'It uses more battery, because the app stays connected. It puts a permanent notice on your phone saying the app is running: anyone who unlocks your phone and looks can see it, and it stays there until you turn this off. It is hidden on the lock screen.'**
  String get sustainedWhatItCosts;

  /// No description provided for @sustainedWhatItCannotPromise.
  ///
  /// In en, this message translates to:
  /// **'Your phone is allowed to stop it at any time and will not say so. It stops completely if you force-stop the app, or set its battery use to restricted. This app cannot promise it will keep working, only that it will tell you here when it can see that it is not.'**
  String get sustainedWhatItCannotPromise;

  /// No description provided for @sustainedNeedsTitle.
  ///
  /// In en, this message translates to:
  /// **'What your phone needs from you'**
  String get sustainedNeedsTitle;

  /// No description provided for @sustainedNeedsAlerts.
  ///
  /// In en, this message translates to:
  /// **'Permission to show notifications. Without it a message could arrive and nothing would tell you.'**
  String get sustainedNeedsAlerts;

  /// No description provided for @sustainedNeedsExemption.
  ///
  /// In en, this message translates to:
  /// **'Permission to keep working while your phone saves battery. Your phone will ask you directly.'**
  String get sustainedNeedsExemption;

  /// No description provided for @sustainedNeedsVendor.
  ///
  /// In en, this message translates to:
  /// **'On Samsung and Xiaomi phones, one more thing: the phone puts unused apps to sleep on its own, and this app must be excluded. Only you can do this, and this app cannot check whether you have.'**
  String get sustainedNeedsVendor;

  /// No description provided for @sustainedVendorAction.
  ///
  /// In en, this message translates to:
  /// **'Open my phone\'s settings'**
  String get sustainedVendorAction;

  /// No description provided for @sustainedTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get sustainedTurnOn;

  /// No description provided for @sustainedTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get sustainedTurnOff;

  /// No description provided for @sustainedStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off. Nothing is running and nothing is shown on your phone.'**
  String get sustainedStatusOff;

  /// No description provided for @sustainedStatusHolding.
  ///
  /// In en, this message translates to:
  /// **'On. The app is being kept open.'**
  String get sustainedStatusHolding;

  /// No description provided for @sustainedStatusAlertsWithheld.
  ///
  /// In en, this message translates to:
  /// **'Notifications are switched off for this app, so this has been stopped. Turn notifications on and it will start again.'**
  String get sustainedStatusAlertsWithheld;

  /// No description provided for @sustainedStatusExemptionWithdrawn.
  ///
  /// In en, this message translates to:
  /// **'Your phone has taken back permission to work while it saves battery, so this has been stopped. This can happen on its own after a phone update. Turn it on again to ask for the permission once more.'**
  String get sustainedStatusExemptionWithdrawn;

  /// No description provided for @sustainedStatusStopped.
  ///
  /// In en, this message translates to:
  /// **'Not running at the moment. Your phone may have stopped it.'**
  String get sustainedStatusStopped;

  /// No description provided for @sustainedStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available in this build.'**
  String get sustainedStatusUnavailable;

  /// No description provided for @sustainedStatusWithheld.
  ///
  /// In en, this message translates to:
  /// **'This build will not turn this on. What it does has not been measured on phones like yours, and offering it before that would be promising something nobody has checked. Nothing is running and nothing is shown on your phone.'**
  String get sustainedStatusWithheld;

  /// No description provided for @sustainedRefusedAlerts.
  ///
  /// In en, this message translates to:
  /// **'Not turned on: notifications are still switched off for this app.'**
  String get sustainedRefusedAlerts;

  /// No description provided for @sustainedRefusedExemption.
  ///
  /// In en, this message translates to:
  /// **'Not turned on: your phone did not give permission to work while it saves battery.'**
  String get sustainedRefusedExemption;

  /// No description provided for @sustainedRefusedPlatform.
  ///
  /// In en, this message translates to:
  /// **'Not turned on: your phone refused to let the app keep running. Some phones do this until the app is excluded from putting apps to sleep.'**
  String get sustainedRefusedPlatform;

  /// No description provided for @sustainedRefusedNotRecorded.
  ///
  /// In en, this message translates to:
  /// **'Not turned on: the choice could not be saved on this phone, and it would not survive a restart.'**
  String get sustainedRefusedNotRecorded;

  /// No description provided for @sustainedRefusedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available in this build.'**
  String get sustainedRefusedUnavailable;

  /// No description provided for @sustainedRefusedWithheld.
  ///
  /// In en, this message translates to:
  /// **'Not turned on: this build does not offer it yet.'**
  String get sustainedRefusedWithheld;

  /// No description provided for @settingsSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {username}'**
  String settingsSignedInAs(String username);

  /// No description provided for @settingsProfileSummary.
  ///
  /// In en, this message translates to:
  /// **'Your display name and photo, and what other people can see'**
  String get settingsProfileSummary;

  /// No description provided for @settingsSavedMessagesSummary.
  ///
  /// In en, this message translates to:
  /// **'Notes to yourself, kept on this phone'**
  String get settingsSavedMessagesSummary;

  /// No description provided for @settingsSecurityTitle.
  ///
  /// In en, this message translates to:
  /// **'Security & recovery'**
  String get settingsSecurityTitle;

  /// No description provided for @settingsSecuritySummary.
  ///
  /// In en, this message translates to:
  /// **'Replace your recovery secret and review verified contacts'**
  String get settingsSecuritySummary;

  /// No description provided for @settingsAppearanceSummary.
  ///
  /// In en, this message translates to:
  /// **'Theme and language on this phone only'**
  String get settingsAppearanceSummary;

  /// No description provided for @settingsAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// No description provided for @settingsAboutSummary.
  ///
  /// In en, this message translates to:
  /// **'Version, what this build is, and a report you can copy'**
  String get settingsAboutSummary;

  /// No description provided for @settingsLogOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get settingsLogOutTitle;

  /// No description provided for @settingsLogOutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Log out of this device?'**
  String get settingsLogOutConfirmTitle;

  /// No description provided for @settingsLogOutConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Everything this phone holds is erased: your messages, your contacts and the keys that decrypt them. The server keeps no copy of your history, so nothing comes back when you sign in again — only another device that still has your history can send it to you. Your recovery secret restores your identity, never your messages.'**
  String get settingsLogOutConfirmBody;

  /// No description provided for @settingsLogOutConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Log out and erase'**
  String get settingsLogOutConfirmAction;

  /// No description provided for @settingsCancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsCancelAction;

  /// No description provided for @appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceTitle;

  /// No description provided for @appearanceLocalOnlyNotice.
  ///
  /// In en, this message translates to:
  /// **'These two settings stay on this phone. They are not sent anywhere and nobody else can see them.'**
  String get appearanceLocalOnlyNotice;

  /// No description provided for @appearanceThemeSection.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get appearanceThemeSection;

  /// No description provided for @appearanceThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow my phone'**
  String get appearanceThemeSystem;

  /// No description provided for @appearanceThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceThemeLight;

  /// No description provided for @appearanceThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceThemeDark;

  /// No description provided for @appearanceContrastNotice.
  ///
  /// In en, this message translates to:
  /// **'High contrast follows your phone’s accessibility settings and has no switch here.'**
  String get appearanceContrastNotice;

  /// No description provided for @appearanceLanguageSection.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get appearanceLanguageSection;

  /// No description provided for @appearanceLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow my phone'**
  String get appearanceLanguageSystem;

  /// No description provided for @appearanceLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get appearanceLanguageEnglish;

  /// No description provided for @appearanceLanguagePersian.
  ///
  /// In en, this message translates to:
  /// **'فارسی'**
  String get appearanceLanguagePersian;

  /// No description provided for @appearanceNotStoredNotice.
  ///
  /// In en, this message translates to:
  /// **'This phone could not save the choice. It applies now and goes back to following your phone when the app restarts.'**
  String get appearanceNotStoredNotice;

  /// No description provided for @securitySettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Security & recovery'**
  String get securitySettingsTitle;

  /// No description provided for @securityRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery secret'**
  String get securityRecoveryTitle;

  /// No description provided for @securityRecoveryBody.
  ///
  /// In en, this message translates to:
  /// **'A recovery secret is shown once, when it is made, and this app never keeps a copy — so it cannot be shown again. If you have lost yours, or somebody else may have seen it, make a new one here. The server holds only an unreadable backup of your identity, never your messages.'**
  String get securityRecoveryBody;

  /// No description provided for @securityRecoveryAction.
  ///
  /// In en, this message translates to:
  /// **'Make a new recovery secret'**
  String get securityRecoveryAction;

  /// No description provided for @securitySafetyNumbersTitle.
  ///
  /// In en, this message translates to:
  /// **'Safety numbers'**
  String get securitySafetyNumbersTitle;

  /// No description provided for @securitySafetyNumbersSummary.
  ///
  /// In en, this message translates to:
  /// **'Which contacts you have checked in person, and which you have not'**
  String get securitySafetyNumbersSummary;

  /// No description provided for @safetyNumbersReviewBody.
  ///
  /// In en, this message translates to:
  /// **'Open a contact to compare their safety number in person or over another channel you trust. Until you do, messaging with them is withheld.'**
  String get safetyNumbersReviewBody;

  /// No description provided for @recoveryRotationTitle.
  ///
  /// In en, this message translates to:
  /// **'New recovery secret'**
  String get recoveryRotationTitle;

  /// No description provided for @recoveryRotationExplain.
  ///
  /// In en, this message translates to:
  /// **'This makes a new secret for the identity you already have. Your contacts stay verified and your other devices stay linked — only the secret that unlocks your identity backup changes.'**
  String get recoveryRotationExplain;

  /// No description provided for @recoveryRotationCost.
  ///
  /// In en, this message translates to:
  /// **'The secret you have now stops working as soon as the new one is made. Write the new one down before you leave this screen: it is shown once and this app keeps no copy.'**
  String get recoveryRotationCost;

  /// No description provided for @recoveryRotationNoHistoryNotice.
  ///
  /// In en, this message translates to:
  /// **'A recovery secret brings back who you are, never what was said. Message history lives on your devices and nowhere else.'**
  String get recoveryRotationNoHistoryNotice;

  /// No description provided for @recoveryRotationStartAction.
  ///
  /// In en, this message translates to:
  /// **'Make the new secret'**
  String get recoveryRotationStartAction;

  /// No description provided for @recoveryRotationWorking.
  ///
  /// In en, this message translates to:
  /// **'Making a new secret…'**
  String get recoveryRotationWorking;

  /// No description provided for @recoveryRotationDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Write this down now'**
  String get recoveryRotationDoneTitle;

  /// No description provided for @recoveryRotationShownOnce.
  ///
  /// In en, this message translates to:
  /// **'This is the only time this secret is shown. The old one no longer works.'**
  String get recoveryRotationShownOnce;

  /// No description provided for @recoveryRotationScreenshotNotice.
  ///
  /// In en, this message translates to:
  /// **'Screenshots are blocked on this screen, and a copy is cleared from the clipboard after a minute.'**
  String get recoveryRotationScreenshotNotice;

  /// No description provided for @recoveryRotationCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy the secret'**
  String get recoveryRotationCopyAction;

  /// No description provided for @recoveryRotationCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Copied. It will be cleared in a minute.'**
  String get recoveryRotationCopiedMessage;

  /// No description provided for @recoveryRotationCopyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This build cannot use the clipboard safely, so copying is switched off. Write the secret down instead.'**
  String get recoveryRotationCopyUnavailable;

  /// No description provided for @recoveryRotationFinishAction.
  ///
  /// In en, this message translates to:
  /// **'I have written it down'**
  String get recoveryRotationFinishAction;

  /// No description provided for @recoveryRotationFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing changed'**
  String get recoveryRotationFailedTitle;

  /// No description provided for @recoveryRotationFailedBody.
  ///
  /// In en, this message translates to:
  /// **'The new secret was not saved on the server, so your current recovery secret still works. Try again when you have a connection.'**
  String get recoveryRotationFailedBody;

  /// No description provided for @recoveryRotationUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'This device has no completed identity to protect, so there is nothing to replace. Finish setting up encryption first.'**
  String get recoveryRotationUnavailableBody;

  /// No description provided for @aboutVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersionLabel;

  /// No description provided for @aboutDisclosureLabel.
  ///
  /// In en, this message translates to:
  /// **'Statement revision'**
  String get aboutDisclosureLabel;

  /// No description provided for @aboutLocalOnlyNotice.
  ///
  /// In en, this message translates to:
  /// **'Everything on this screen was read from this phone. Nothing was fetched and nothing was sent.'**
  String get aboutLocalOnlyNotice;

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics report'**
  String get diagnosticsTitle;

  /// No description provided for @diagnosticsSummary.
  ///
  /// In en, this message translates to:
  /// **'A short technical report you can copy and send to whoever runs your server'**
  String get diagnosticsSummary;

  /// No description provided for @diagnosticsExplain.
  ///
  /// In en, this message translates to:
  /// **'This is everything the report contains, exactly as it will be copied. It carries no message, no name, no address, no key and no identifier — only settings, states and rough counts.'**
  String get diagnosticsExplain;

  /// No description provided for @diagnosticsNothingSentNotice.
  ///
  /// In en, this message translates to:
  /// **'Copying puts it on this phone’s clipboard. The app sends it nowhere; where it goes next is your choice.'**
  String get diagnosticsNothingSentNotice;

  /// No description provided for @diagnosticsLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Reading this device…'**
  String get diagnosticsLoadingTitle;

  /// No description provided for @diagnosticsCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy the report'**
  String get diagnosticsCopyAction;

  /// No description provided for @diagnosticsCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Report copied.'**
  String get diagnosticsCopiedMessage;

  /// No description provided for @diagnosticsCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'This phone did not let the app use the clipboard.'**
  String get diagnosticsCopyFailed;

  /// No description provided for @diagnosticsRefreshAction.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get diagnosticsRefreshAction;

  /// No description provided for @chatSearchTruncatedNotice.
  ///
  /// In en, this message translates to:
  /// **'Showing the first {shown} matches. Type more of the message to narrow it down.'**
  String chatSearchTruncatedNotice(int shown);

  /// No description provided for @chatSearchResultCount.
  ///
  /// In en, this message translates to:
  /// **'{count} matches on this phone'**
  String chatSearchResultCount(int count);

  /// No description provided for @chatClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear this conversation?'**
  String get chatClearHistoryTitle;

  /// No description provided for @chatClearHistoryBody.
  ///
  /// In en, this message translates to:
  /// **'Every message in this conversation is removed from this phone and cannot be brought back here. The other person keeps their copy, and your other devices keep theirs.'**
  String get chatClearHistoryBody;

  /// No description provided for @chatClearHistoryAction.
  ///
  /// In en, this message translates to:
  /// **'Clear on this phone'**
  String get chatClearHistoryAction;

  /// No description provided for @linkedDevicesRefreshAction.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get linkedDevicesRefreshAction;

  /// No description provided for @linkedDevicesLabelsEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Device names are encrypted on this phone'**
  String get linkedDevicesLabelsEncrypted;

  /// No description provided for @linkedDevicesLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Loading your devices'**
  String get linkedDevicesLoadingTitle;

  /// No description provided for @linkedDevicesUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Device list unavailable'**
  String get linkedDevicesUnavailableTitle;

  /// No description provided for @linkedDevicesUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'This device could not read the list. Check your connection and try again.'**
  String get linkedDevicesUnavailableMessage;

  /// No description provided for @linkedDevicesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No other devices'**
  String get linkedDevicesEmptyTitle;

  /// No description provided for @linkedDevicesThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get linkedDevicesThisDevice;

  /// No description provided for @linkedDevicesUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Unnamed device'**
  String get linkedDevicesUnnamed;

  /// No description provided for @linkedDevicesCurrentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The device you are using now'**
  String get linkedDevicesCurrentSubtitle;

  /// No description provided for @linkedDevicesAdded.
  ///
  /// In en, this message translates to:
  /// **'Added: {date}'**
  String linkedDevicesAdded(String date);

  /// No description provided for @linkedDevicesRenameAction.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get linkedDevicesRenameAction;

  /// No description provided for @linkedDevicesRemoveAction.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get linkedDevicesRemoveAction;

  /// No description provided for @linkedDevicesRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename device'**
  String get linkedDevicesRenameTitle;

  /// No description provided for @linkedDevicesRenameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get linkedDevicesRenameLabel;

  /// No description provided for @linkedDevicesSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get linkedDevicesSaveAction;

  /// No description provided for @linkedDevicesRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this device?'**
  String get linkedDevicesRemoveTitle;

  /// No description provided for @linkedDevicesRemoveSelfTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove the device you are using?'**
  String get linkedDevicesRemoveSelfTitle;

  /// No description provided for @linkedDevicesRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'The device stops being able to read new messages, and this cannot be undone. Everything it holds stays on it until it is signed out or erased.'**
  String get linkedDevicesRemoveBody;

  /// No description provided for @linkedDevicesRemoveSelfBody.
  ///
  /// In en, this message translates to:
  /// **'This phone is signed out and everything on it is erased, including your messages and the keys that decrypt them. This cannot be undone.'**
  String get linkedDevicesRemoveSelfBody;

  /// No description provided for @linkedDevicesAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add another device'**
  String get linkedDevicesAddTitle;

  /// No description provided for @linkedDevicesAddBody.
  ///
  /// In en, this message translates to:
  /// **'Install the app on the other device, sign in there, and enter your recovery secret when it asks. It appears in this list once it is signed. Keep this phone online afterwards so it can send your history across; the server has no copy to send.'**
  String get linkedDevicesAddBody;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
