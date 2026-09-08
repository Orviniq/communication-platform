// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Communication Platform';

  @override
  String get developmentAppTitle => 'Communication Platform (Development)';

  @override
  String get experimentalAppTitle => 'Communication Platform (Experimental)';

  @override
  String get developmentConfiguration => 'Development configuration';

  @override
  String get betaConfiguration => 'Private experimental build';

  @override
  String get foundationReady => 'Flutter foundation is ready';

  @override
  String get bootstrapLoadingConfiguration => 'Loading secure configuration…';

  @override
  String get bootstrapCheckingStorage => 'Checking protected storage…';

  @override
  String get bootstrapDiscoveringIdentity => 'Checking this device…';

  @override
  String get bootstrapValidatingTrust => 'Verifying server trust…';

  @override
  String get bootstrapCheckingServer => 'Connecting to the server…';

  @override
  String get bootstrapReady => 'Ready';

  @override
  String get notProvisionedTitle => 'App not provisioned';

  @override
  String get notProvisionedMessage =>
      'Install a provisioned copy of this app from a trusted source. There is no connection bypass.';

  @override
  String get protectedStorageUnavailableTitle =>
      'Protected storage unavailable';

  @override
  String get protectedStorageUnavailableMessage =>
      'This device cannot safely open local identity or session data. Fix protected storage, then retry.';

  @override
  String get trustFailureTitle => 'Server trust could not be verified';

  @override
  String get androidTrustFailureMessage =>
      'The private certificate authority or server certificate pins do not match this provisioned app. Reinstall a trusted provisioned copy or contact the operator. You cannot continue past this check.';

  @override
  String get webTrustFailureMessage =>
      'Install the operator-provided private certificate authority in this operating system or browser, verify its fingerprint through the independent provisioning channel, then retry. The web app cannot install or bypass certificate trust.';

  @override
  String get serverUnreachableTitle => 'Can\'t reach the server';

  @override
  String get serverUnreachableMessage =>
      'Check access to the provisioned server and try again.';

  @override
  String get retryAction => 'Retry';

  @override
  String get loginDestination => 'Login';

  @override
  String get chatsDestination => 'Chats';

  @override
  String get voiceRoomsDestination => 'Voice Rooms';

  @override
  String get settingsDestination => 'Settings';

  @override
  String get maturityExperimentalLabel => 'Experimental';

  @override
  String get maturityNotBuiltLabel => 'Not built yet';

  @override
  String get settingsLinkedDevicesTitle => 'Linked Devices';

  @override
  String get settingsLinkedDevicesSummary =>
      'Review, rename, or revoke devices on this account';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsNotificationsTitle => 'Notifications';

  @override
  String get settingsNotificationsOn =>
      'On. An alert says only that something arrived, never who sent it or what it says. It can reach you while the app is closed, but only when your phone next lets the app look for messages.';

  @override
  String get settingsNotificationsOff =>
      'Off. Nothing will tell you a message arrived unless you are looking at the app.';

  @override
  String get settingsNotificationsUnavailable => 'Not available in this build.';

  @override
  String get settingsNotificationsTurnOn => 'Turn on';

  @override
  String get notificationsChannelName => 'Messages';

  @override
  String get notificationsChannelDescription =>
      'Tells you that something arrived. It never shows who sent it or what it says.';

  @override
  String get notificationsNewMessage => 'New message';

  @override
  String get notificationsNewMessages => 'New messages';

  @override
  String get chatsPlaceholderTitle => 'Chats structure';

  @override
  String get chatsPlaceholderBody =>
      'The routed conversation list and detail regions are ready for later feature pieces.';

  @override
  String get voiceRoomsPlaceholderTitle => 'Voice rooms';

  @override
  String get voiceRoomsPlaceholderBody =>
      'Voice rooms are not built yet. This build sends and receives no audio.';

  @override
  String get settingsPlaceholderTitle => 'Settings structure';

  @override
  String get settingsPlaceholderBody =>
      'The routed settings list and detail regions are ready for later feature pieces.';

  @override
  String get threadPlaceholderTitle => 'Conversation detail';

  @override
  String get roomPlaceholderTitle => 'Voice room detail';

  @override
  String get newChatPlaceholderTitle => 'New conversation';

  @override
  String get newRoomPlaceholderTitle => 'Create voice room';

  @override
  String get placeholderBody => 'This part of the app is not built yet.';

  @override
  String get composeChat => 'Start a conversation';

  @override
  String get composeVoiceRoom => 'Create a voice room';

  @override
  String get connectingStatus => 'Connecting…';

  @override
  String get offlineStatus => 'No connection to server';

  @override
  String returnToVoiceRoom(String roomName) {
    return 'Return to voice room: $roomName';
  }

  @override
  String get keyboardNavigationHint =>
      'Keyboard: Alt+1 Chats, Alt+2 Voice Rooms, Alt+3 Settings';

  @override
  String routeLabel(String route) {
    return 'Route: $route';
  }

  @override
  String get authLoginTitle => 'Log in';

  @override
  String get authLoginSubtitle =>
      'Sign in to your account on the provisioned server.';

  @override
  String get authRegisterTitle => 'Create account';

  @override
  String get authRegisterSubtitle =>
      'Choose a username and password. The owner must activate the account before you can use it.';

  @override
  String get authUsernameLabel => 'Username';

  @override
  String get authPasswordLabel => 'Password';

  @override
  String get authConfirmPasswordLabel => 'Confirm password';

  @override
  String get authUsernameHint =>
      '3–32 lowercase letters, numbers, or underscores';

  @override
  String get authPasswordHint => '10–256 characters';

  @override
  String get authPasswordPurpose =>
      'Your password signs you in. It cannot recover your cryptographic identity or message history.';

  @override
  String get authLoginAction => 'Log in';

  @override
  String get authLoggingInAction => 'Logging in…';

  @override
  String get authCreateAccountAction => 'Create account';

  @override
  String get authCreatingAccountAction => 'Creating account…';

  @override
  String get authSecurityNoticeAction => 'Security & how this app protects you';

  @override
  String get securityNoticeTitle =>
      'What this app protects — and what it doesn\'t';

  @override
  String get authBackToLoginAction => 'Back to login';

  @override
  String get authBackAction => 'Back';

  @override
  String get authUsernameFormatError =>
      'Use 3–32 letters, numbers, or underscores.';

  @override
  String get authPasswordLengthError =>
      'Password must be between 10 and 256 characters.';

  @override
  String get authPasswordsMismatchError => 'Passwords do not match.';

  @override
  String get authInvalidCredentialsMessage =>
      'Username or password is incorrect.';

  @override
  String get authInactiveAccountMessage =>
      'This account is waiting for the owner to activate it.';

  @override
  String get authUsernameTakenMessage => 'That username is already taken.';

  @override
  String get authRateLimitedMessage =>
      'Too many attempts. Please wait and try again.';

  @override
  String get authOfflineMessage =>
      'The provisioned server cannot be reached. Check your connection and try again.';

  @override
  String get authMalformedResponseMessage =>
      'The server returned an invalid response. Try again or contact the operator.';

  @override
  String get authInvalidInputMessage =>
      'Check the highlighted information and try again.';

  @override
  String get authSessionExpiredMessage =>
      'Your session has expired. Log in again.';

  @override
  String get authRevokedMessage =>
      'This session is no longer valid. Local data from this installation was removed.';

  @override
  String get authStorageUnavailableMessage =>
      'Protected storage is unavailable. Fix device storage and try again.';

  @override
  String get authGenericErrorMessage =>
      'Something went wrong. Please try again.';

  @override
  String get authPendingTitle => 'Waiting for activation';

  @override
  String get authPendingMessage =>
      'Your account is waiting for the owner to activate it.';

  @override
  String get authPendingNoPollingMessage =>
      'There is no automatic activation check. When the owner has activated your account, return to login and enter your password again.';

  @override
  String get authCheckAgainAction => 'Check again';

  @override
  String get authRestoringSession => 'Restoring your secure session…';

  @override
  String get authSecurityNoticeMessage =>
      'Your login password authenticates your account. A separate recovery secret protects cryptographic identity material. Neither secret restores message history from the server.';

  @override
  String get enrollmentSetupTitle => 'Setting up encryption on this device';

  @override
  String get enrollmentWithheldMessage =>
      'Finishing secure device setup. Messaging stays unavailable until every security step completes.';

  @override
  String get enrollmentRecoveryTitle => 'Your recovery secret';

  @override
  String get enrollmentRecoveryExplanation =>
      'Save this secret somewhere safe. It restores your account\'s cryptographic identity if your devices are lost. It does not restore messages; the server has no message-history copy.';

  @override
  String get enrollmentRecoverySeparate =>
      'This recovery secret is separate from your login password. The server never sees it.';

  @override
  String get enrollmentCopyAction => 'Copy';

  @override
  String get enrollmentCopiedMessage =>
      'Recovery secret copied. The clipboard will be cleared shortly.';

  @override
  String get enrollmentSavedCheck =>
      'I\'ve saved the recovery secret somewhere safe.';

  @override
  String get enrollmentContinueAction => 'Continue';

  @override
  String get enrollmentConfirmTitle => 'Confirm your recovery secret is safe';

  @override
  String get enrollmentConfirmCheck =>
      'Yes, I\'ve stored my recovery secret somewhere safe.';

  @override
  String get enrollmentConfirmAction => 'Confirm and finish setup';

  @override
  String get enrollmentBackToSecretAction => 'Back to recovery secret';

  @override
  String get enrollmentRestoreTitle => 'Restore cryptographic identity';

  @override
  String get enrollmentRestoreExplanation =>
      'Enter your recovery secret to unlock the encrypted identity backup on this device. Message history is not in this backup.';

  @override
  String get enrollmentRecoverySecretLabel => 'Recovery secret';

  @override
  String get enrollmentRestoreAction => 'Restore identity';

  @override
  String get enrollmentRestoringAction => 'Restoring identity…';

  @override
  String get enrollmentWrongSecretMessage =>
      'The recovery secret could not unlock this identity backup. Check it and try again.';

  @override
  String get enrollmentAmbiguousTitle => 'Registration needs reconciliation';

  @override
  String get enrollmentAmbiguousMessage =>
      'The server may have registered this device before the response was lost. The app will not register another device until it can safely reconcile the unsigned device.';

  @override
  String get enrollmentReconcileAction => 'Reconcile registration';

  @override
  String get enrollmentDeviceLimitMessage =>
      'This account has reached its device limit. Remove an old device from an existing installation, then retry.';

  @override
  String get enrollmentIdentityRequiredMessage =>
      'The account identity must be repaired from an existing device before another device can be added.';

  @override
  String get enrollmentBackupMissingMessage =>
      'No identity backup is available. This device cannot be cross-signed with a recovery secret.';

  @override
  String get enrollmentStaleVersionMessage =>
      'A newer identity or backup version exists. Secure setup is blocked to avoid overwriting it.';

  @override
  String get enrollmentInvalidVectorMessage =>
      'Security verification failed. This device remains unverified and messaging is unavailable.';

  @override
  String get enrollmentLogConflictMessage =>
      'The signed device log changed concurrently or did not match. Secure setup is blocked.';

  @override
  String get enrollmentUnsupportedMessage =>
      'This installation does not support the required secure enrollment protocol.';

  @override
  String get enrollmentGenericMessage =>
      'Secure setup could not continue. Try again.';

  @override
  String get enrollmentIdentityRecoveredTitle => 'Identity recovered';

  @override
  String get enrollmentNoHistoryMessage =>
      'Your cryptographic identity is ready. No message history was restored: history can only come later from an existing online device, and history transfer is not part of this setup.';

  @override
  String get enrollmentProtectsHeading => 'What it DOES protect';

  @override
  String get enrollmentProtectsBody =>
      'Everything you write is encrypted on this phone before it leaves it. The server, anyone watching the network, and anyone who takes the server can see that you are using this app, but not what you wrote.';

  @override
  String get enrollmentDoesNotProtectHeading => 'What it does NOT protect';

  @override
  String get enrollmentDoesNotProtectBody =>
      'It does not hide when you connect, from where, how much you send, or who you talk to. Whoever runs the server can see all of that. It cannot tell you that a new contact is really who they say they are until you and they compare the safety number this app shows, in person or over another channel you trust. And it cannot protect messages already open on a phone somebody else has taken or broken into.';

  @override
  String get enrollmentUnderstandAction => 'I understand';

  @override
  String get disclosureBuildTitle => 'What this build is';

  @override
  String get disclosureNoIndependentReview =>
      'Nobody outside the project has reviewed this app\'s encryption. It is written and tested by one person, and a mistake in it would not have been caught.';

  @override
  String get disclosureBestEffortDelivery =>
      'While this app is open, messages arrive as they are sent. While it is closed, your phone looks for new ones on its own schedule — fifteen minutes apart at best, usually far less often, and not at all while it is saving battery, while Data Saver is on and you are using mobile data, if you have not opened the app for several days, or if you have force-stopped it. In Settings you can turn on receiving while closed, which does better on most phones but uses more battery and shows a permanent notice while it is on. Nothing about any of this is guaranteed, so do not rely on it for anything urgent.';

  @override
  String get disclosureMessagesExpireUnread =>
      'A message waits on the server only until your phone collects it. After a time set by whoever runs the server, whatever is still waiting is deleted and never arrives, and you will not be told which messages those were. If you go a long time without opening the app, assume you have missed some.';

  @override
  String get disclosureDeviceOnlyHistory =>
      'Your messages are stored only on this phone. The server keeps no copy of your history and no backup exists, so uninstalling the app destroys it permanently.';

  @override
  String get disclosureRecoveryExcludesHistory =>
      'Your recovery secret restores your account identity on a new device. It never restores messages; those can only come from another device of yours that still works.';

  @override
  String get disclosureExperimentalGroups =>
      'Group chats use experimental encryption that is not finished, not standardised, and has not been independently reviewed. An update can reset a group and delete everything in it. On a phone whose processor it has not been tested on, group chats are switched off instead.';

  @override
  String get disclosureUnbuiltSurfaces =>
      'Some things you can see are not built yet: voice rooms and file attachments do nothing, and the display name and photo you choose are not published — other people see the username you registered with.';

  @override
  String get disclosureIntendedUse =>
      'This build is for trying out among people who already trust each other. It is not suitable if your safety depends on your messages staying private.';

  @override
  String get disclosureChangedTitle => 'What this app tells you has changed';

  @override
  String get disclosureChangedLead =>
      'You accepted an earlier version of the statement below. Some of it was wrong or has changed, so it is being shown again. The parts that are new or different are marked.';

  @override
  String get disclosureChangedLabel => 'New or changed';

  @override
  String get contactsNewTitle => 'New';

  @override
  String get contactsNewGroup => 'New Group';

  @override
  String get contactsNewGroupClosed => 'Not available on this device';

  @override
  String get contactsNewVoiceRoom => 'New Voice Room';

  @override
  String get contactsSearchLabel => 'Search contacts';

  @override
  String get contactsLoadingTitle => 'Loading contacts';

  @override
  String get contactsEmptyTitle => 'No contacts yet';

  @override
  String get contactsEmptyMessage =>
      'Activated users will appear here after the directory refreshes.';

  @override
  String get contactsOfflineMessage => 'Offline — showing cached contacts';

  @override
  String get contactsLoadMore => 'Load more contacts';

  @override
  String get contactsVerified => 'Identity verified';

  @override
  String get contactsUnverified => 'Identity not verified';

  @override
  String get contactsUsernameFallback =>
      'Backend username shown until the encrypted profile and identity are authenticated.';

  @override
  String get contactProfileTitle => 'Contact profile';

  @override
  String get contactMessageAction => 'Message';

  @override
  String get contactMuteAction => 'Mute';

  @override
  String get contactVerifyAction => 'Verify safety number';

  @override
  String get contactSharedMediaAction => 'Shared media and files';

  @override
  String get contactClearHistoryAction => 'Clear history';

  @override
  String get contactBlockAction => 'Block';

  @override
  String get contactSensitiveBlocked =>
      'Messaging is withheld until this identity and every device pass verification.';

  @override
  String get profileEditTitle => 'Edit profile';

  @override
  String get profileDisplayNameLabel => 'Display name';

  @override
  String get profileVisibilityNote =>
      'This encrypted profile is visible only to contacts who receive an authenticated profile key. Keep personal information minimal.';

  @override
  String get profileAvatarStyleLabel => 'Avatar style';

  @override
  String get profileSaveAction => 'Save encrypted profile';

  @override
  String get profileSavingAction => 'Saving…';

  @override
  String get profileTemporaryTransport =>
      'Development build only: profile encryption and key delivery here are a stand-in, not real cryptography.';

  @override
  String get profileNotBuiltNotice =>
      'This build cannot publish a profile yet. The name and photo you choose here are not sent anywhere, and your contacts see the username you registered with.';

  @override
  String get profileSavedMessage => 'Encrypted profile published.';

  @override
  String get profileInvalidName =>
      'Enter a display name of 1 to 64 characters.';

  @override
  String get safetyTitle => 'Safety number';

  @override
  String get safetyInstructions =>
      'Compare these values in person or over another trusted channel. The server cannot confirm them for you.';

  @override
  String get safetyEmojiLabel => 'Emoji comparison';

  @override
  String get safetyNumberLabel => 'Number comparison';

  @override
  String get safetyQrLabel => 'QR safety value';

  @override
  String get safetyOutOfBandCheck =>
      'I compared the values out of band with this contact.';

  @override
  String get safetyConfirmAction => 'Confirm verified';

  @override
  String get safetyVerifiedState =>
      'Verified — the exact master key is attested by your user-signing key.';

  @override
  String get safetyUnverifiedState => 'Unverified — messaging withheld';

  @override
  String get safetyMasterChangedState =>
      'Master key changed — sensitive actions are blocked until you verify the new values out of band.';

  @override
  String get safetyInvalidDeviceState =>
      'Unsigned or invalid device — messages are withheld.';

  @override
  String get safetyForkState =>
      'Device-log fork detected — all sensitive actions are blocked.';

  @override
  String get safetyIdentityUnavailableState =>
      'A valid signed identity is unavailable.';

  @override
  String get safetyRefreshing =>
      'Verifying identity, devices, prekeys, and device log…';

  @override
  String get safetyRetryAction => 'Retry verification';

  @override
  String get safetyConfirmationRequired =>
      'Out-of-band comparison is required before confirmation.';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get chatsSearchAction => 'Search chats';

  @override
  String get chatsSearchHint => 'Search names and the latest message';

  @override
  String get chatsClearSearchAction => 'Clear search';

  @override
  String get chatsLoadingTitle => 'Loading chats';

  @override
  String get chatsErrorTitle => 'Chats are unavailable';

  @override
  String get chatsErrorMessage =>
      'The encrypted local conversation list could not be opened.';

  @override
  String get chatsEmptyTitle => 'No chats yet';

  @override
  String get chatsEmptyMessage =>
      'Start a verified direct message. Conversations will remain readable offline on this device.';

  @override
  String get chatsStartAction => 'Start a chat';

  @override
  String get chatsNoSearchResultsTitle => 'Nothing found on this phone';

  @override
  String get chatsDeviceSearchScopeNotice =>
      'This searches only the messages stored on this phone. The server never sees them, or what you search for.';

  @override
  String get chatsListSearchScopeNotice =>
      'This list matches names and the latest message only. To search a conversation\'s history, open it and search inside.';

  @override
  String get chatsDeliveryConnectingNotice => 'Connecting…';

  @override
  String get chatsDeliverySyncingNotice => 'Syncing…';

  @override
  String get chatsDeliveryWaitingNotice => 'Waiting to reconnect…';

  @override
  String get chatsOfflineCachedNotice =>
      'Offline — showing cached conversations. New messages will queue locally.';

  @override
  String get chatsNoMessagesPreview => 'No messages yet';

  @override
  String get chatsConversationActionsLabel => 'Conversation actions';

  @override
  String get chatsMuteAction => 'Mute for 8 hours';

  @override
  String get chatsUnmuteAction => 'Unmute';

  @override
  String get chatsMarkReadAction => 'Mark as read';

  @override
  String get chatsMarkUnreadAction => 'Mark as unread';

  @override
  String get chatsDeleteAction => 'Delete chat';

  @override
  String get chatsDeleteTitle => 'Delete this chat?';

  @override
  String get chatsDeleteLocalOnlyMessage =>
      'Clearing a chat removes this device\'s local view only. It does not delete content already received by other devices.';

  @override
  String chatsItemSemantics(String title, String preview, int unreadCount) {
    return '$title. $preview. $unreadCount unread messages.';
  }

  @override
  String get chatTitle => 'Conversation';

  @override
  String get savedMessagesTitle => 'Saved Messages';

  @override
  String get savedMessagesEmptyTitle => 'Nothing saved yet';

  @override
  String get savedMessagesEmptyMessage =>
      'Messages here are local to your encrypted self-conversation and never show peer presence or receipts.';

  @override
  String get savedMessagesComposerHint => 'Write a note to yourself';

  @override
  String get chatHistoryLoading => 'Loading encrypted history';

  @override
  String get chatHistoryErrorTitle => 'History is unavailable';

  @override
  String get chatHistoryErrorMessage =>
      'The encrypted local history could not be read. No server copy exists.';

  @override
  String get chatEmptyTitle => 'Start the conversation';

  @override
  String get chatEmptyMessage =>
      'Messages are encrypted on this device before they enter the delivery queue.';

  @override
  String chatTimelineSemantics(String title) {
    return 'Message timeline for $title';
  }

  @override
  String chatMessageSemantics(String author, String message, String state) {
    return '$author: $message. State: $state.';
  }

  @override
  String get chatMessageActionsLabel => 'Message actions';

  @override
  String get chatReplyAction => 'Reply';

  @override
  String get chatEditAction => 'Edit';

  @override
  String get chatForwardAction => 'Forward';

  @override
  String get chatCopyAction => 'Copy';

  @override
  String get chatStarAction => 'Star on this device';

  @override
  String get chatUnstarAction => 'Remove star';

  @override
  String get chatPinAction => 'Pin';

  @override
  String get chatUnpinAction => 'Unpin';

  @override
  String get chatDeleteAction => 'Delete';

  @override
  String get chatDeleteTitle => 'Delete message?';

  @override
  String get chatDeleteHonestMessage =>
      'Delete for me removes this device\'s local copy. Delete for everyone is best-effort and cannot force another device to forget content it already received and decrypted.';

  @override
  String get chatDeleteForMeAction => 'Delete for me';

  @override
  String get chatDeleteForEveryoneAction => 'Delete for everyone';

  @override
  String get chatCancelAction => 'Cancel';

  @override
  String get chatDeletedMessage => 'Message deleted';

  @override
  String get chatUnsupportedMessage =>
      'This message needs a newer supported protocol. Its encrypted record was retained.';

  @override
  String get chatSystemMessage => 'Conversation update';

  @override
  String get chatEditedLabel => 'edited';

  @override
  String get chatTimestampSkewed =>
      'The sender\'s clock appears inaccurate; this time is display-only.';

  @override
  String get chatReplyQuote => 'Replied message';

  @override
  String chatReactionSemantics(String emoji, int count) {
    return '$emoji reaction, $count people';
  }

  @override
  String get chatReactionSelectorLabel => 'Choose a reaction';

  @override
  String chatReactionAddAction(String emoji) {
    return 'React with $emoji';
  }

  @override
  String chatReactionRemoveAction(String emoji) {
    return 'Remove your $emoji reaction';
  }

  @override
  String get chatMoreReactionsAction => 'More emoji';

  @override
  String get chatRetrySendAction => 'Retry as a new encrypted send';

  @override
  String get chatUnreadDivider => 'Unread messages';

  @override
  String get chatLoadingOlder => 'Loading older messages';

  @override
  String get chatLoadOlderAction => 'Load older messages';

  @override
  String get chatOlderErrorAction => 'Older messages could not load — retry';

  @override
  String get chatBeginningOfHistory => 'Beginning of local history';

  @override
  String get chatJumpToLatestAction => 'Jump to latest message';

  @override
  String get chatComposerHint => 'Message';

  @override
  String get chatAttachAction => 'Attach';

  @override
  String get chatEmojiAction => 'Insert emoji';

  @override
  String get chatEmojiPanelCloseAction => 'Close emoji panel';

  @override
  String get emojiPickerLabel => 'Emoji picker';

  @override
  String get emojiPickerSearchHint => 'Search emoji';

  @override
  String get chatSendAction => 'Send encrypted message';

  @override
  String get chatSaveEditAction => 'Save encrypted edit';

  @override
  String get chatCancelContextAction => 'Cancel reply or edit';

  @override
  String get chatEditingMessage => 'Editing message';

  @override
  String chatReplyingTo(String author) {
    return 'Replying to $author';
  }

  @override
  String get chatOfflineQueueNotice =>
      'Offline — sending stores encrypted queue work locally until this server is reachable.';

  @override
  String get chatWithheldUnverifiedIdentity =>
      'Messaging withheld: verify this identity out of band before sending.';

  @override
  String get chatWithheldUnverifiedDevice =>
      'Messaging withheld: an unsigned or invalid device cannot receive messages.';

  @override
  String get chatWithheldMasterChanged =>
      'Messaging withheld: the contact\'s master key changed and must be verified again.';

  @override
  String get chatWithheldLogFork =>
      'Messaging withheld: a device-log fork indicates possible server equivocation.';

  @override
  String get chatWithheldPq =>
      'Messaging withheld: required ML-KEM post-quantum key material is unavailable. The app will not downgrade.';

  @override
  String chatPinnedBanner(int count) {
    return '$count pinned messages';
  }

  @override
  String get chatPinnedExpandAction => 'View all';

  @override
  String get chatPinnedMessagesTitle => 'Pinned messages';

  @override
  String get chatTypingStatus => 'typing… encrypted signal may lag';

  @override
  String get chatSearchAction => 'Search in chat';

  @override
  String get chatSearchInputLabel => 'Search local messages';

  @override
  String get chatSearchEmptyQueryTitle => 'Search this device\'s history';

  @override
  String get chatMoreAction => 'More conversation actions';

  @override
  String get chatYouAuthor => 'You';

  @override
  String get chatAttachmentsUnavailable => 'Open or save verified file';

  @override
  String get attachmentChoosePrompt => 'Choose encrypted media or a file.';

  @override
  String get attachmentsNotBuiltNotice =>
      'File attachments are not built yet. Nothing can be attached to a message in this build.';

  @override
  String get attachmentPhotoOption => 'Photo or image';

  @override
  String get attachmentFileOption => 'File';

  @override
  String get attachmentCameraOption => 'Camera';

  @override
  String get attachmentImageLabel => 'Encrypted image';

  @override
  String get attachmentFileLabel => 'Encrypted attachment';

  @override
  String get attachmentOpenHint => 'Open after local verification';

  @override
  String get attachmentQueuedState => 'attachment queued';

  @override
  String get attachmentDownloadingState => 'downloading attachment';

  @override
  String get attachmentVerifyingState => 'verifying attachment';

  @override
  String get attachmentReadyState => 'verified attachment';

  @override
  String get attachmentExpiredState => 'attachment expired';

  @override
  String get attachmentCancelledState => 'attachment cancelled';

  @override
  String get attachmentQuotaState => 'attachment quota exceeded';

  @override
  String get attachmentUnsupportedState => 'attachment unsupported';

  @override
  String get attachmentCorruptState => 'attachment corrupt';

  @override
  String get attachmentFailedState => 'attachment failed';

  @override
  String attachmentDetails(String mimeType, int size) {
    return '$mimeType · $size bytes';
  }

  @override
  String get chatActionFailedMessage =>
      'That action could not be completed. No security guarantee was weakened.';

  @override
  String get chatStateLocalOnly => 'saved locally only';

  @override
  String get chatStateQueued => 'queued offline';

  @override
  String get chatStateEncrypting => 'encrypting';

  @override
  String get chatStateSending => 'sending to server';

  @override
  String get chatStateAccepted => 'accepted by server relay';

  @override
  String get chatStateDelivered => 'durably delivered to a recipient device';

  @override
  String get chatStateRead => 'read receipt received';

  @override
  String get chatStateFailed => 'send failed';

  @override
  String get chatStateReceived => 'received';

  @override
  String get groupProductionUnavailableTitle =>
      'Production groups are not available';

  @override
  String get groupProductionUnavailableMessage =>
      'The post-quantum MLS profile is still gated. This build cannot create groups, generate KeyPackages, or send group ciphertext.';

  @override
  String get groupExperimentalWithheldTitle =>
      'Group messaging is not available on this device';

  @override
  String get groupExperimentalWithheldMessage =>
      'The experimental group encryption has been tested on 64-bit ARM phones, and this device uses a different processor. Rather than run it untested, group chats are switched off here: no keys are published for you and no group message can reach this device. Direct messages are unaffected.';

  @override
  String get groupDevelopmentPreviewBanner =>
      'Development preview only — no production group ciphertext is sent';

  @override
  String get groupExperimentalBanner =>
      'Experimental group encryption — not reviewed or standardized. An update may reset these groups and delete their messages.';

  @override
  String get groupCreateTitle => 'Create Group';

  @override
  String get groupPickMembersTitle => 'Pick members';

  @override
  String get groupDetailsTitle => 'Group details';

  @override
  String get groupNextAction => 'Next';

  @override
  String get groupBackAction => 'Back';

  @override
  String get groupCreateAction => 'Create';

  @override
  String get groupCreatingState => 'Creating local group preview…';

  @override
  String get groupCreateFailed =>
      'The group could not be created. Nothing was sent.';

  @override
  String get groupSelectMemberMessage => 'Select at least one member.';

  @override
  String get groupMemberLimitMessage =>
      'A group can have at most 50 members, including you.';

  @override
  String get groupNameLabel => 'Group name';

  @override
  String get groupDescriptionLabel => 'Description (optional)';

  @override
  String get groupPhotoAction => 'Choose encrypted photo';

  @override
  String get groupPhotoSelected => 'A local preview photo is selected';

  @override
  String get groupSearchMembersLabel => 'Search members';

  @override
  String groupSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String groupMemberCount(int count) {
    return '$count members';
  }

  @override
  String get groupInfoTitle => 'Group Info';

  @override
  String get groupEditTitle => 'Edit Group';

  @override
  String get groupEditAction => 'Edit';

  @override
  String get groupAddMembersAction => 'Add members';

  @override
  String get groupLeaveAction => 'Leave group';

  @override
  String get groupRemoveAction => 'Remove from group';

  @override
  String get groupPromoteAction => 'Make admin';

  @override
  String get groupDemoteAction => 'Make member';

  @override
  String get groupTransferOwnerAction => 'Transfer ownership';

  @override
  String get groupRoleOwner => 'Owner';

  @override
  String get groupRoleAdmin => 'Admin';

  @override
  String get groupRoleMember => 'Member';

  @override
  String get groupInvitePolicyLabel => 'Who can add members';

  @override
  String get groupInviteOwnerOnly => 'Owner only';

  @override
  String get groupInviteAdmins => 'Owner and admins';

  @override
  String get groupInviteEveryone => 'All members';

  @override
  String get groupHistorySharingLabel =>
      'Show available past history to new members';

  @override
  String get groupHistorySharingNote =>
      'When this is on, an existing member’s device intentionally re-shares the backlog to the newcomer. The server cannot reconstruct or send that history, and the source device may have only partial history.';

  @override
  String get groupSaveAction => 'Save';

  @override
  String get groupCancelAction => 'Cancel';

  @override
  String get groupPermissionChanged =>
      'Your role changed. These settings can no longer be saved.';

  @override
  String get groupMembershipUpdatingState =>
      'Membership is updating. Sending and member changes are paused.';

  @override
  String get groupRemovedState =>
      'You were removed. Past content on this device stays readable, but future group epochs are unavailable.';

  @override
  String get groupLeftState => 'You left this group. This copy is read-only.';

  @override
  String get groupQueueGapState =>
      'A mailbox gap may have hidden an MLS commit. This device must be removed and re-added with a fresh Welcome before sending.';

  @override
  String get groupForkState =>
      'Concurrent MLS commits were quarantined. The client will not choose a branch.';

  @override
  String get groupControlQuarantineState =>
      'An invalid or unauthorized group control was quarantined.';

  @override
  String get groupReadOnlyLabel => 'Read-only group';

  @override
  String get groupMessageHint => 'Message group';

  @override
  String get groupSendFailed => 'The message was not saved. Nothing was sent.';

  @override
  String get groupMuteAction => 'Mute';

  @override
  String get groupSearchChatAction => 'Search in chat';

  @override
  String get groupSharedMediaAction => 'Shared media';

  @override
  String get groupNoDescription => 'No description';

  @override
  String get groupMembersSection => 'Members';

  @override
  String get groupVerifiedMember => 'Verified identity';

  @override
  String get groupConfirmRemoveTitle => 'Remove member?';

  @override
  String get groupConfirmRemoveBody =>
      'Removing this member advances the group epoch and cuts off access to future messages. It cannot erase content already received.';

  @override
  String get groupConfirmLeaveTitle => 'Leave group?';

  @override
  String get groupConfirmLeaveBody =>
      'You will lose access to future group epochs. Content already stored on this device remains readable.';

  @override
  String get groupOwnerMustTransfer =>
      'Transfer ownership before leaving this group.';

  @override
  String get groupActionFailed =>
      'That group change could not be committed. The previous group state is unchanged.';

  @override
  String get groupMemberPickerEmpty => 'No eligible contacts found';

  @override
  String get groupWithheldUpdating =>
      'Messaging withheld: membership is updating.';

  @override
  String get groupWithheldRemoved =>
      'Messaging withheld: this group is read-only on this device.';

  @override
  String get groupWithheldQueueGap =>
      'Messaging withheld: rejoin with a fresh Welcome after the mailbox gap.';

  @override
  String get groupWithheldConflict =>
      'Messaging withheld: a group control conflict is quarantined.';

  @override
  String get sustainedNotificationTitle => 'Kept open in the background';

  @override
  String get sustainedChannelName => 'Running in the background';

  @override
  String get sustainedChannelDescription =>
      'Shown while the app is kept open so that messages can arrive.';

  @override
  String get settingsSustainedTitle => 'Receiving while closed';

  @override
  String get settingsSustainedOff =>
      'Off. Your phone looks for messages on its own schedule, which is slow and often not at all.';

  @override
  String get settingsSustainedHolding =>
      'On. The app is kept open in the background, and there is a permanent notice on your phone while it is.';

  @override
  String get settingsSustainedAlertsWithheld =>
      'On, but notifications are switched off, so nothing would tell you a message arrived.';

  @override
  String get settingsSustainedExemptionWithdrawn =>
      'On, but your phone has taken back permission to run while it saves battery.';

  @override
  String get settingsSustainedStopped => 'On, but it is not running right now.';

  @override
  String get settingsSustainedUnavailable => 'Not available in this build.';

  @override
  String get settingsSustainedWithheld =>
      'Not offered in this build. It has not been tested on phones like yours yet.';

  @override
  String get sustainedTitle => 'Receiving while closed';

  @override
  String get sustainedWhatItDoes =>
      'Normally your phone stops this app when you leave it, and only lets it look for new messages every fifteen minutes at best. Turned on, the app is kept open in the background instead, so a message can reach you without waiting for that. How quickly it does on your phone has not been measured.';

  @override
  String get sustainedWhatItCosts =>
      'It uses more battery, because the app stays connected. It puts a permanent notice on your phone saying the app is running: anyone who unlocks your phone and looks can see it, and it stays there until you turn this off. It is hidden on the lock screen.';

  @override
  String get sustainedWhatItCannotPromise =>
      'Your phone is allowed to stop it at any time and will not say so. It stops completely if you force-stop the app, or set its battery use to restricted. This app cannot promise it will keep working, only that it will tell you here when it can see that it is not.';

  @override
  String get sustainedNeedsTitle => 'What your phone needs from you';

  @override
  String get sustainedNeedsAlerts =>
      'Permission to show notifications. Without it a message could arrive and nothing would tell you.';

  @override
  String get sustainedNeedsExemption =>
      'Permission to keep working while your phone saves battery. Your phone will ask you directly.';

  @override
  String get sustainedNeedsVendor =>
      'On Samsung and Xiaomi phones, one more thing: the phone puts unused apps to sleep on its own, and this app must be excluded. Only you can do this, and this app cannot check whether you have.';

  @override
  String get sustainedVendorAction => 'Open my phone\'s settings';

  @override
  String get sustainedTurnOn => 'Turn on';

  @override
  String get sustainedTurnOff => 'Turn off';

  @override
  String get sustainedStatusOff =>
      'Off. Nothing is running and nothing is shown on your phone.';

  @override
  String get sustainedStatusHolding => 'On. The app is being kept open.';

  @override
  String get sustainedStatusAlertsWithheld =>
      'Notifications are switched off for this app, so this has been stopped. Turn notifications on and it will start again.';

  @override
  String get sustainedStatusExemptionWithdrawn =>
      'Your phone has taken back permission to work while it saves battery, so this has been stopped. This can happen on its own after a phone update. Turn it on again to ask for the permission once more.';

  @override
  String get sustainedStatusStopped =>
      'Not running at the moment. Your phone may have stopped it.';

  @override
  String get sustainedStatusUnavailable => 'Not available in this build.';

  @override
  String get sustainedStatusWithheld =>
      'This build will not turn this on. What it does has not been measured on phones like yours, and offering it before that would be promising something nobody has checked. Nothing is running and nothing is shown on your phone.';

  @override
  String get sustainedRefusedAlerts =>
      'Not turned on: notifications are still switched off for this app.';

  @override
  String get sustainedRefusedExemption =>
      'Not turned on: your phone did not give permission to work while it saves battery.';

  @override
  String get sustainedRefusedPlatform =>
      'Not turned on: your phone refused to let the app keep running. Some phones do this until the app is excluded from putting apps to sleep.';

  @override
  String get sustainedRefusedNotRecorded =>
      'Not turned on: the choice could not be saved on this phone, and it would not survive a restart.';

  @override
  String get sustainedRefusedUnavailable => 'Not available in this build.';

  @override
  String get sustainedRefusedWithheld =>
      'Not turned on: this build does not offer it yet.';

  @override
  String settingsSignedInAs(String username) {
    return 'Signed in as $username';
  }

  @override
  String get settingsProfileSummary =>
      'Your display name and photo, and what other people can see';

  @override
  String get settingsSavedMessagesSummary =>
      'Notes to yourself, kept on this phone';

  @override
  String get settingsSecurityTitle => 'Security & recovery';

  @override
  String get settingsSecuritySummary =>
      'Replace your recovery secret and review verified contacts';

  @override
  String get settingsAppearanceSummary =>
      'Theme and language on this phone only';

  @override
  String get settingsAboutTitle => 'About';

  @override
  String get settingsAboutSummary =>
      'Version, what this build is, and a report you can copy';

  @override
  String get settingsLogOutTitle => 'Log out';

  @override
  String get settingsLogOutConfirmTitle => 'Log out of this device?';

  @override
  String get settingsLogOutConfirmBody =>
      'Everything this phone holds is erased: your messages, your contacts and the keys that decrypt them. The server keeps no copy of your history, so nothing comes back when you sign in again — only another device that still has your history can send it to you. Your recovery secret restores your identity, never your messages.';

  @override
  String get settingsLogOutConfirmAction => 'Log out and erase';

  @override
  String get settingsCancelAction => 'Cancel';

  @override
  String get settingsEraseAccountTitle => 'Erase this account';

  @override
  String get settingsEraseAccountSummary =>
      'Delete everything the server holds for this account. This cannot be undone.';

  @override
  String get eraseAccountConfirmTitle => 'Erase this account?';

  @override
  String get eraseAccountServerScope =>
      'Everything the server holds for this account is deleted: your devices, your keys, your published identity, your profile, and every message still waiting to be delivered to you.';

  @override
  String get eraseAccountPeerCopies =>
      'The copies other people hold are not erased. Every message you sent was decrypted on the phone of the person you sent it to and is stored there. Nothing in this reaches another device.';

  @override
  String eraseAccountAttachments(int days) {
    return 'Files you uploaded stay on the server for up to $days days, until the retention window ends. Nothing stored with a file names your account, so there is no set of them this can delete.';
  }

  @override
  String get eraseAccountUsernameFreed =>
      'Your username becomes free again at once. Someone else may register it.';

  @override
  String get eraseAccountPasswordLabel => 'Your password';

  @override
  String get eraseAccountPasswordPurpose =>
      'The password is sent with this one request and is stored nowhere.';

  @override
  String get eraseAccountAction => 'Erase account';

  @override
  String get eraseAccountWorkingAction => 'Erasing…';

  @override
  String eraseAccountWrongPassword(int used, int allowed) {
    return 'That password is wrong. $used of $allowed tries used. After $allowed wrong tries this username is locked for fifteen minutes — here and on the sign-in screen, on every device.';
  }

  @override
  String eraseAccountThrottled(String wait) {
    return 'Too many attempts. Try again in $wait.';
  }

  @override
  String get eraseAccountThrottledUnknownWait =>
      'Too many attempts. Try again later.';

  @override
  String eraseAccountWaitMinutes(int minutes) {
    return '$minutes minutes';
  }

  @override
  String eraseAccountWaitSeconds(int seconds) {
    return '$seconds seconds';
  }

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceLocalOnlyNotice =>
      'These two settings stay on this phone. They are not sent anywhere and nobody else can see them.';

  @override
  String get appearanceThemeSection => 'Theme';

  @override
  String get appearanceThemeSystem => 'Follow my phone';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceContrastNotice =>
      'High contrast follows your phone’s accessibility settings and has no switch here.';

  @override
  String get appearanceLanguageSection => 'Language';

  @override
  String get appearanceLanguageSystem => 'Follow my phone';

  @override
  String get appearanceLanguageEnglish => 'English';

  @override
  String get appearanceLanguagePersian => 'فارسی';

  @override
  String get appearanceNotStoredNotice =>
      'This phone could not save the choice. It applies now and goes back to following your phone when the app restarts.';

  @override
  String get securitySettingsTitle => 'Security & recovery';

  @override
  String get securityRecoveryTitle => 'Recovery secret';

  @override
  String get securityRecoveryBody =>
      'A recovery secret is shown once, when it is made, and this app never keeps a copy — so it cannot be shown again. If you have lost yours, or somebody else may have seen it, make a new one here. The server holds only an unreadable backup of your identity, never your messages.';

  @override
  String get securityRecoveryAction => 'Make a new recovery secret';

  @override
  String get securitySafetyNumbersTitle => 'Safety numbers';

  @override
  String get securitySafetyNumbersSummary =>
      'Which contacts you have checked in person, and which you have not';

  @override
  String get safetyNumbersReviewBody =>
      'Open a contact to compare their safety number in person or over another channel you trust. Until you do, messaging with them is withheld.';

  @override
  String get recoveryRotationTitle => 'New recovery secret';

  @override
  String get recoveryRotationExplain =>
      'This makes a new secret for the identity you already have. Your contacts stay verified and your other devices stay linked — only the secret that unlocks your identity backup changes.';

  @override
  String get recoveryRotationCost =>
      'The secret you have now stops working as soon as the new one is made. Write the new one down before you leave this screen: it is shown once and this app keeps no copy.';

  @override
  String get recoveryRotationNoHistoryNotice =>
      'A recovery secret brings back who you are, never what was said. Message history lives on your devices and nowhere else.';

  @override
  String get recoveryRotationStartAction => 'Make the new secret';

  @override
  String get recoveryRotationWorking => 'Making a new secret…';

  @override
  String get recoveryRotationDoneTitle => 'Write this down now';

  @override
  String get recoveryRotationShownOnce =>
      'This is the only time this secret is shown. The old one no longer works.';

  @override
  String get recoveryRotationScreenshotNotice =>
      'Screenshots are blocked on this screen, and a copy is cleared from the clipboard after a minute.';

  @override
  String get recoveryRotationCopyAction => 'Copy the secret';

  @override
  String get recoveryRotationCopiedMessage =>
      'Copied. It will be cleared in a minute.';

  @override
  String get recoveryRotationCopyUnavailable =>
      'This build cannot use the clipboard safely, so copying is switched off. Write the secret down instead.';

  @override
  String get recoveryRotationFinishAction => 'I have written it down';

  @override
  String get recoveryRotationFailedTitle => 'Nothing changed';

  @override
  String get recoveryRotationFailedBody =>
      'The new secret was not saved on the server, so your current recovery secret still works. Try again when you have a connection.';

  @override
  String get recoveryRotationUnavailableBody =>
      'This device has no completed identity to protect, so there is nothing to replace. Finish setting up encryption first.';

  @override
  String get aboutVersionLabel => 'Version';

  @override
  String get aboutDisclosureLabel => 'Statement revision';

  @override
  String get aboutLocalOnlyNotice =>
      'Everything on this screen was read from this phone. Nothing was fetched and nothing was sent.';

  @override
  String get diagnosticsTitle => 'Diagnostics report';

  @override
  String get diagnosticsSummary =>
      'A short technical report you can copy and send to whoever runs your server';

  @override
  String get diagnosticsExplain =>
      'This is everything the report contains, exactly as it will be copied. It carries no message, no name, no address, no key and no identifier — only settings, states and rough counts.';

  @override
  String get diagnosticsNothingSentNotice =>
      'Copying puts it on this phone’s clipboard. The app sends it nowhere; where it goes next is your choice.';

  @override
  String get diagnosticsLoadingTitle => 'Reading this device…';

  @override
  String get diagnosticsCopyAction => 'Copy the report';

  @override
  String get diagnosticsCopiedMessage => 'Report copied.';

  @override
  String get diagnosticsCopyFailed =>
      'This phone did not let the app use the clipboard.';

  @override
  String get diagnosticsRefreshAction => 'Read again';

  @override
  String chatSearchTruncatedNotice(int shown) {
    return 'Showing the first $shown matches. Type more of the message to narrow it down.';
  }

  @override
  String chatSearchResultCount(int count) {
    return '$count matches on this phone';
  }

  @override
  String get chatClearHistoryTitle => 'Clear this conversation?';

  @override
  String get chatClearHistoryBody =>
      'Every message in this conversation is removed from this phone and cannot be brought back here. The other person keeps their copy, and your other devices keep theirs.';

  @override
  String get chatClearHistoryAction => 'Clear on this phone';

  @override
  String get linkedDevicesRefreshAction => 'Refresh';

  @override
  String get linkedDevicesLabelsEncrypted =>
      'Device names are encrypted on this phone';

  @override
  String get linkedDevicesLoadingTitle => 'Loading your devices';

  @override
  String get linkedDevicesUnavailableTitle => 'Device list unavailable';

  @override
  String get linkedDevicesUnavailableMessage =>
      'This device could not read the list. Check your connection and try again.';

  @override
  String get linkedDevicesEmptyTitle => 'No other devices';

  @override
  String get linkedDevicesThisDevice => 'This device';

  @override
  String get linkedDevicesUnnamed => 'Unnamed device';

  @override
  String get linkedDevicesCurrentSubtitle => 'The device you are using now';

  @override
  String linkedDevicesAdded(String date) {
    return 'Added: $date';
  }

  @override
  String get linkedDevicesRenameAction => 'Rename';

  @override
  String get linkedDevicesRemoveAction => 'Remove';

  @override
  String get linkedDevicesRenameTitle => 'Rename device';

  @override
  String get linkedDevicesRenameLabel => 'Device name';

  @override
  String get linkedDevicesSaveAction => 'Save';

  @override
  String get linkedDevicesRemoveTitle => 'Remove this device?';

  @override
  String get linkedDevicesRemoveSelfTitle => 'Remove the device you are using?';

  @override
  String get linkedDevicesRemoveBody =>
      'The device stops being able to read new messages, and this cannot be undone. Everything it holds stays on it until it is signed out or erased.';

  @override
  String get linkedDevicesRemoveSelfBody =>
      'This phone is signed out and everything on it is erased, including your messages and the keys that decrypt them. This cannot be undone.';

  @override
  String get linkedDevicesAddTitle => 'Add another device';

  @override
  String get linkedDevicesAddBody =>
      'Install the app on the other device, sign in there, and enter your recovery secret when it asks. It appears in this list once it is signed. Keep this phone online afterwards so it can send your history across; the server has no copy to send.';
}
