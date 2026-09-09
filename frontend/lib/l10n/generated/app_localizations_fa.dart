// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get appTitle => 'پلتفرم ارتباطی';

  @override
  String get developmentAppTitle => 'پلتفرم ارتباطی (توسعه)';

  @override
  String get experimentalAppTitle => 'پلتفرم ارتباطی (آزمایشی)';

  @override
  String get developmentConfiguration => 'پیکربندی توسعه';

  @override
  String get betaConfiguration => 'نسخهٔ آزمایشی خصوصی';

  @override
  String get foundationReady => 'پایهٔ فلاتر آماده است';

  @override
  String get bootstrapLoadingConfiguration => 'در حال بارگذاری پیکربندی امن…';

  @override
  String get bootstrapCheckingStorage => 'در حال بررسی ذخیره‌سازی محافظت‌شده…';

  @override
  String get bootstrapDiscoveringIdentity => 'در حال بررسی این دستگاه…';

  @override
  String get bootstrapValidatingTrust => 'در حال تأیید اعتماد سرور…';

  @override
  String get bootstrapCheckingServer => 'در حال اتصال به سرور…';

  @override
  String get bootstrapReady => 'آماده';

  @override
  String get notProvisionedTitle => 'برنامه تأمین نشده است';

  @override
  String get notProvisionedMessage =>
      'نسخه‌ای تأمین‌شده از یک منبع مطمئن نصب کنید. راهی برای دور زدن بررسی اتصال وجود ندارد.';

  @override
  String get protectedStorageUnavailableTitle =>
      'ذخیره‌سازی محافظت‌شده در دسترس نیست';

  @override
  String get protectedStorageUnavailableMessage =>
      'این دستگاه نمی‌تواند هویت یا نشست محلی را به‌شکل امن باز کند. مشکل ذخیره‌سازی را رفع و دوباره تلاش کنید.';

  @override
  String get trustFailureTitle => 'اعتماد سرور تأیید نشد';

  @override
  String get androidTrustFailureMessage =>
      'مرجع گواهی خصوصی یا پین‌های گواهی سرور با این برنامه همخوانی ندارد. یک نسخه تأمین‌شده و مطمئن نصب کنید یا با مدیر تماس بگیرید. امکان ادامه وجود ندارد.';

  @override
  String get webTrustFailureMessage =>
      'مرجع گواهی خصوصی ارائه‌شده توسط مدیر را در سیستم‌عامل یا مرورگر نصب کنید، اثر انگشت آن را از مسیر مستقل تأمین بررسی کنید و دوباره تلاش کنید. برنامه وب نمی‌تواند اعتماد گواهی را نصب یا دور بزند.';

  @override
  String get serverUnreachableTitle => 'سرور در دسترس نیست';

  @override
  String get serverUnreachableMessage =>
      'دسترسی به سرور تأمین‌شده را بررسی کنید و دوباره تلاش کنید.';

  @override
  String get retryAction => 'تلاش مجدد';

  @override
  String get loginDestination => 'ورود';

  @override
  String get chatsDestination => 'گفت‌وگوها';

  @override
  String get voiceRoomsDestination => 'اتاق‌های صوتی';

  @override
  String get settingsDestination => 'تنظیمات';

  @override
  String get maturityExperimentalLabel => 'آزمایشی';

  @override
  String get maturityNotBuiltLabel => 'هنوز ساخته نشده';

  @override
  String get settingsLinkedDevicesTitle => 'دستگاه‌های متصل';

  @override
  String get settingsLinkedDevicesSummary =>
      'دستگاه‌های این حساب را ببینید، تغییر نام دهید یا باطل کنید';

  @override
  String get settingsAppearanceTitle => 'نمایش';

  @override
  String get settingsNotificationsTitle => 'اعلان‌ها';

  @override
  String get settingsNotificationsOn =>
      'روشن. اعلان فقط می‌گوید چیزی رسیده است؛ هرگز نمی‌گوید از طرف چه کسی است یا چه نوشته شده. وقتی برنامه بسته است هم می‌تواند به شما برسد، اما فقط زمانی که گوشی‌تان دوباره به برنامه اجازه بدهد دنبال پیام بگردد.';

  @override
  String get settingsNotificationsOff =>
      'خاموش. تا وقتی به برنامه نگاه نکنید، هیچ چیز به شما نمی‌گوید پیامی رسیده است.';

  @override
  String get settingsNotificationsUnavailable => 'در این نسخه در دسترس نیست.';

  @override
  String get settingsNotificationsTurnOn => 'روشن کن';

  @override
  String get notificationsChannelName => 'پیام‌ها';

  @override
  String get notificationsChannelDescription =>
      'به شما خبر می‌دهد که چیزی رسیده است. هرگز نشان نمی‌دهد از طرف چه کسی است یا چه نوشته شده.';

  @override
  String get notificationsNewMessage => 'پیام تازه';

  @override
  String get notificationsNewMessages => 'پیام‌های تازه';

  @override
  String get chatsPlaceholderTitle => 'ساختار گفت‌وگوها';

  @override
  String get chatsPlaceholderBody =>
      'فهرست مسیریابی‌شدهٔ گفت‌وگوها و ناحیهٔ جزئیات برای بخش‌های بعدی آماده است.';

  @override
  String get voiceRoomsPlaceholderTitle => 'اتاق‌های صوتی';

  @override
  String get voiceRoomsPlaceholderBody =>
      'اتاق‌های صوتی هنوز ساخته نشده‌اند. این نسخه هیچ صدایی نمی‌فرستد و دریافت نمی‌کند.';

  @override
  String get settingsPlaceholderTitle => 'ساختار تنظیمات';

  @override
  String get settingsPlaceholderBody =>
      'فهرست مسیریابی‌شدهٔ تنظیمات و ناحیهٔ جزئیات برای بخش‌های بعدی آماده است.';

  @override
  String get threadPlaceholderTitle => 'جزئیات گفت‌وگو';

  @override
  String get roomPlaceholderTitle => 'جزئیات اتاق صوتی';

  @override
  String get newChatPlaceholderTitle => 'گفت‌وگوی جدید';

  @override
  String get newRoomPlaceholderTitle => 'ساخت اتاق صوتی';

  @override
  String get placeholderBody => 'این بخش از برنامه هنوز ساخته نشده است.';

  @override
  String get composeChat => 'شروع گفت‌وگو';

  @override
  String get composeVoiceRoom => 'ساخت اتاق صوتی';

  @override
  String get connectingStatus => 'در حال اتصال…';

  @override
  String get offlineStatus => 'ارتباط با سرور برقرار نیست';

  @override
  String returnToVoiceRoom(String roomName) {
    return 'بازگشت به اتاق صوتی: $roomName';
  }

  @override
  String get keyboardNavigationHint =>
      'صفحه‌کلید: Alt+1 گفت‌وگوها، Alt+2 اتاق‌های صوتی، Alt+3 تنظیمات';

  @override
  String routeLabel(String route) {
    return 'مسیر: $route';
  }

  @override
  String get authLoginTitle => 'ورود';

  @override
  String get authLoginSubtitle => 'به حساب خود در سرور تأمین‌شده وارد شوید.';

  @override
  String get authRegisterTitle => 'ساخت حساب';

  @override
  String get authRegisterSubtitle =>
      'نام کاربری و رمز عبوری انتخاب کنید. پیش از استفاده، مالک باید حساب را فعال کند.';

  @override
  String get authUsernameLabel => 'نام کاربری';

  @override
  String get authPasswordLabel => 'رمز عبور';

  @override
  String get authConfirmPasswordLabel => 'تکرار رمز عبور';

  @override
  String get authUsernameHint => '۳ تا ۳۲ حرف کوچک انگلیسی، رقم یا زیرخط';

  @override
  String get authPasswordHint => '۱۰ تا ۲۵۶ نویسه';

  @override
  String get authPasswordPurpose =>
      'رمز عبور فقط برای ورود است و نمی‌تواند هویت رمزنگاری یا تاریخچه پیام‌ها را بازیابی کند.';

  @override
  String get authLoginAction => 'ورود';

  @override
  String get authLoggingInAction => 'در حال ورود…';

  @override
  String get authCreateAccountAction => 'ساخت حساب';

  @override
  String get authCreatingAccountAction => 'در حال ساخت حساب…';

  @override
  String get authSecurityNoticeAction => 'امنیت و روش محافظت این برنامه';

  @override
  String get securityNoticeTitle =>
      'این برنامه از چه چیزهایی محافظت می‌کند — و از چه چیزهایی نه';

  @override
  String get authBackToLoginAction => 'بازگشت به ورود';

  @override
  String get authBackAction => 'بازگشت';

  @override
  String get authUsernameFormatError =>
      'از ۳ تا ۳۲ حرف، رقم یا زیرخط استفاده کنید.';

  @override
  String get authPasswordLengthError =>
      'رمز عبور باید بین ۱۰ تا ۲۵۶ نویسه باشد.';

  @override
  String get authPasswordsMismatchError => 'رمزهای عبور یکسان نیستند.';

  @override
  String get authInvalidCredentialsMessage =>
      'نام کاربری یا رمز عبور نادرست است.';

  @override
  String get authInactiveAccountMessage =>
      'این حساب در انتظار فعال‌سازی توسط مالک است.';

  @override
  String get authUsernameTakenMessage => 'این نام کاربری قبلاً انتخاب شده است.';

  @override
  String get authRateLimitedMessage =>
      'تلاش‌های بیش از حد. کمی صبر کنید و دوباره تلاش کنید.';

  @override
  String get authOfflineMessage =>
      'سرور تأمین‌شده در دسترس نیست. اتصال را بررسی و دوباره تلاش کنید.';

  @override
  String get authMalformedResponseMessage =>
      'پاسخ سرور نامعتبر بود. دوباره تلاش کنید یا با مدیر تماس بگیرید.';

  @override
  String get authInvalidInputMessage =>
      'اطلاعات مشخص‌شده را بررسی و دوباره تلاش کنید.';

  @override
  String get authSessionExpiredMessage =>
      'نشست شما منقضی شده است. دوباره وارد شوید.';

  @override
  String get authRevokedMessage =>
      'این نشست دیگر معتبر نیست. داده‌های محلی این نصب حذف شد.';

  @override
  String get authStorageUnavailableMessage =>
      'ذخیره‌سازی محافظت‌شده در دسترس نیست. مشکل ذخیره‌سازی را رفع و دواره تلاش کنید.';

  @override
  String get authGenericErrorMessage => 'مشکلی پیش آمد. دوباره تلاش کنید.';

  @override
  String get authPendingTitle => 'در انتظار فعال‌سازی';

  @override
  String get authPendingMessage =>
      'حساب شما در انتظار فعال‌سازی توسط مالک است.';

  @override
  String get authPendingNoPollingMessage =>
      'بررسی خودکاری برای فعال‌سازی وجود ندارد. پس از فعال‌سازی توسط مالک، به ورود بازگردید و رمز عبور را دوباره وارد کنید.';

  @override
  String get authCheckAgainAction => 'بررسی دوباره';

  @override
  String get authRestoringSession => 'در حال بازیابی نشست امن…';

  @override
  String get authSecurityNoticeMessage =>
      'رمز عبور، حساب شما را احراز می‌کند. یک راز بازیابی جداگانه از مواد هویت رمزنگاری محافظت می‌کند. هیچ‌یک تاریخچه پیام‌ها را از سرور بازیابی نمی‌کند.';

  @override
  String get enrollmentSetupTitle =>
      'در حال راه‌اندازی رمزنگاری روی این دستگاه';

  @override
  String get enrollmentWithheldMessage =>
      'راه‌اندازی امن دستگاه در حال تکمیل است. پیام‌رسانی تا پایان همهٔ مراحل امنیتی در دسترس نیست.';

  @override
  String get enrollmentRecoveryTitle => 'راز بازیابی شما';

  @override
  String get enrollmentRecoveryExplanation =>
      'این راز را در جای امن نگه دارید. اگر دستگاه‌هایتان را از دست بدهید، هویت رمزنگاری حساب را بازیابی می‌کند. پیام‌ها را بازیابی نمی‌کند؛ سرور نسخه‌ای از تاریخچهٔ پیام‌ها ندارد.';

  @override
  String get enrollmentRecoverySeparate =>
      'راز بازیابی با رمز عبور ورود جداست و سرور هرگز آن را نمی‌بیند.';

  @override
  String get enrollmentCopyAction => 'کپی';

  @override
  String get enrollmentCopiedMessage =>
      'راز بازیابی کپی شد. حافظهٔ موقت به‌زودی پاک می‌شود.';

  @override
  String get enrollmentSavedCheck => 'راز بازیابی را در جای امن ذخیره کرده‌ام.';

  @override
  String get enrollmentContinueAction => 'ادامه';

  @override
  String get enrollmentConfirmTitle => 'ایمن‌بودن راز بازیابی را تأیید کنید';

  @override
  String get enrollmentConfirmCheck =>
      'بله، راز بازیابی را در جای امن نگه داشته‌ام.';

  @override
  String get enrollmentConfirmAction => 'تأیید و تکمیل راه‌اندازی';

  @override
  String get enrollmentBackToSecretAction => 'بازگشت به راز بازیابی';

  @override
  String get enrollmentRestoreTitle => 'بازیابی هویت رمزنگاری';

  @override
  String get enrollmentRestoreExplanation =>
      'برای بازکردن نسخهٔ پشتیبان رمزگذاری‌شدهٔ هویت روی این دستگاه، راز بازیابی را وارد کنید. تاریخچهٔ پیام در این نسخه نیست.';

  @override
  String get enrollmentRecoverySecretLabel => 'راز بازیابی';

  @override
  String get enrollmentRestoreAction => 'بازیابی هویت';

  @override
  String get enrollmentRestoringAction => 'در حال بازیابی هویت…';

  @override
  String get enrollmentWrongSecretMessage =>
      'این راز بازیابی نتوانست نسخهٔ پشتیبان هویت را باز کند. آن را بررسی و دوباره تلاش کنید.';

  @override
  String get enrollmentAmbiguousTitle => 'ثبت دستگاه نیاز به تطبیق دارد';

  @override
  String get enrollmentAmbiguousMessage =>
      'ممکن است سرور پیش از گم‌شدن پاسخ، دستگاه را ثبت کرده باشد. برنامه تا تطبیق امن دستگاه بدون امضا، دستگاه دیگری ثبت نمی‌کند.';

  @override
  String get enrollmentReconcileAction => 'تطبیق ثبت دستگاه';

  @override
  String get enrollmentDeviceLimitMessage =>
      'حساب به سقف تعداد دستگاه رسیده است. یک دستگاه قدیمی را از نصب موجود حذف و دوباره تلاش کنید.';

  @override
  String get enrollmentIdentityRequiredMessage =>
      'پیش از افزودن دستگاه دیگر، هویت حساب باید از یک دستگاه موجود ترمیم شود.';

  @override
  String get enrollmentBackupMissingMessage =>
      'نسخهٔ پشتیبان هویت موجود نیست. این دستگاه با راز بازیابی قابل امضای متقابل نیست.';

  @override
  String get enrollmentStaleVersionMessage =>
      'نسخهٔ جدیدتری از هویت یا پشتیبان وجود دارد. برای جلوگیری از بازنویسی، راه‌اندازی امن متوقف شد.';

  @override
  String get enrollmentInvalidVectorMessage =>
      'اعتبارسنجی امنیتی ناموفق بود. دستگاه تأییدنشده می‌ماند و پیام‌رسانی در دسترس نیست.';

  @override
  String get enrollmentLogConflictMessage =>
      'دفتر امضاشدهٔ دستگاه‌ها هم‌زمان تغییر کرد یا تطبیق نداشت. راه‌اندازی امن متوقف شد.';

  @override
  String get enrollmentUnsupportedMessage =>
      'این نصب از پروتکل لازم برای ثبت امن پشتیبانی نمی‌کند.';

  @override
  String get enrollmentGenericMessage =>
      'راه‌اندازی امن ادامه پیدا نکرد. دوباره تلاش کنید.';

  @override
  String get enrollmentIdentityRecoveredTitle => 'هویت بازیابی شد';

  @override
  String get enrollmentNoHistoryMessage =>
      'هویت رمزنگاری شما آماده است. هیچ تاریخچهٔ پیامی بازیابی نشد؛ تاریخچه فقط بعداً از یک دستگاه آنلاین موجود می‌آید و انتقال آن بخشی از این راه‌اندازی نیست.';

  @override
  String get enrollmentProtectsHeading => 'از چه چیزهایی محافظت می‌کند';

  @override
  String get enrollmentProtectsBody =>
      'هر چه می‌نویسید پیش از آنکه این گوشی را ترک کند روی همین گوشی رمزنگاری می‌شود. سرور، هر کسی که شبکه را تماشا می‌کند و هر کسی که سرور را در اختیار بگیرد می‌بینند که شما از این برنامه استفاده می‌کنید، اما نمی‌بینند چه نوشته‌اید.';

  @override
  String get enrollmentDoesNotProtectHeading => 'از چه چیزهایی محافظت نمی‌کند';

  @override
  String get enrollmentDoesNotProtectBody =>
      'پنهان نمی‌کند که کِی وصل می‌شوید، از کجا، چه اندازه می‌فرستید، یا با چه کسی گفت‌وگو می‌کنید؛ هر کسی که سرور را می‌گرداند همهٔ این‌ها را می‌بیند. تا وقتی شما و مخاطب تازه‌تان «شمارهٔ ایمنی» را که همین برنامه نشان می‌دهد حضوری یا از راه دیگری که به آن اعتماد دارید با هم مقایسه نکرده‌اید، برنامه نمی‌تواند بگوید او واقعاً همان کسی است که ادعا می‌کند. و از پیام‌هایی که روی گوشیِ ربوده‌شده یا نفوذشده از پیش باز شده‌اند محافظت نمی‌کند.';

  @override
  String get enrollmentUnderstandAction => 'متوجه شدم';

  @override
  String get disclosureBuildTitle => 'این نسخه چیست';

  @override
  String get disclosureNoIndependentReview =>
      'هیچ‌کس بیرون از این پروژه رمزنگاری این برنامه را بازبینی نکرده است. همه‌چیز را یک نفر نوشته و آزموده است و اگر اشتباهی در آن باشد، کسی آن را نگرفته است.';

  @override
  String get disclosureBestEffortDelivery =>
      'تا وقتی این برنامه باز است، پیام‌ها همان لحظه‌ای که فرستاده می‌شوند می‌رسند. وقتی بسته است، گوشی شما بر اساس زمان‌بندی خودش دنبال پیام تازه می‌گردد — دست‌بالا هر پانزده دقیقه، معمولاً خیلی کمتر، و اصلاً وقتی گوشی در حال ذخیرهٔ باتری است، وقتی «صرفه‌جویی در مصرف داده» روشن است و از دادهٔ همراه استفاده می‌کنید، یا چند روز برنامه را باز نکرده باشید، یا آن را به‌اجبار متوقف کرده باشید. در تنظیمات می‌توانید دریافت هنگام بسته بودن را روشن کنید؛ روی بیشتر گوشی‌ها بهتر کار می‌کند اما باتری بیشتری مصرف می‌کند و تا وقتی روشن است یک اعلان دائمی نشان می‌دهد. هیچ‌کدام از این‌ها تضمین نیست؛ پس برای چیزی که فوری است به آن تکیه نکنید.';

  @override
  String get disclosureMessagesExpireUnread =>
      'پیام فقط تا وقتی روی سرور می‌ماند که گوشی شما آن را بگیرد. پس از مدتی که گردانندهٔ سرور تعیین می‌کند، هر چه هنوز مانده باشد حذف می‌شود و هرگز نمی‌رسد، و به شما گفته نمی‌شود کدام پیام‌ها بوده‌اند. اگر مدت زیادی برنامه را باز نکنید، فرض کنید پیام‌هایی را از دست داده‌اید.';

  @override
  String disclosureMessagesExpireUnreadDays(int days) {
    return 'پیام فقط تا وقتی روی سرور می‌ماند که گوشی شما آن را بگیرد. هر چه پس از $days روز هنوز مانده باشد حذف می‌شود و هرگز نمی‌رسد، و به شما گفته نمی‌شود کدام پیام‌ها بوده‌اند. اگر مدت زیادی برنامه را باز نکنید، فرض کنید پیام‌هایی را از دست داده‌اید.';
  }

  @override
  String get disclosureDeviceOnlyHistory =>
      'پیام‌های شما فقط روی همین گوشی ذخیره می‌شوند. سرور هیچ نسخه‌ای از تاریخچهٔ شما ندارد و پشتیبانی گرفته نمی‌شود، پس حذف برنامه آن را برای همیشه از بین می‌برد.';

  @override
  String get disclosureRecoveryExcludesHistory =>
      'راز بازیابی، هویت حساب شما را روی دستگاه تازه برمی‌گرداند. هرگز پیام‌ها را برنمی‌گرداند؛ آن‌ها فقط از دستگاه دیگری از خودتان که هنوز کار می‌کند منتقل می‌شوند.';

  @override
  String get disclosureExperimentalGroups =>
      'گفت‌وگوهای گروهی از رمزنگاری آزمایشی استفاده می‌کنند که نه کامل است، نه استاندارد، و نه به‌طور مستقل بازبینی شده است. یک به‌روزرسانی می‌تواند گروه را بازنشانی کند و هر چه در آن است حذف شود. روی گوشی‌ای که پردازندهٔ آن آزمایش نشده باشد، گفت‌وگوهای گروهی به‌جای آن خاموش است.';

  @override
  String get disclosureUnbuiltSurfaces =>
      'بخش‌هایی که می‌بینید هنوز ساخته نشده‌اند: اتاق‌های صوتی و پیوست فایل کاری انجام نمی‌دهند، و نام و عکسی که انتخاب می‌کنید منتشر نمی‌شود — دیگران همان نام کاربری ثبت‌نامتان را می‌بینند.';

  @override
  String get disclosureIntendedUse =>
      'این نسخه برای آزمودن میان کسانی است که از پیش به هم اعتماد دارند. اگر امنیت شما به محرمانه‌ماندن پیام‌هایتان وابسته است، مناسب نیست.';

  @override
  String get disclosureChangedTitle =>
      'آنچه این برنامه دربارهٔ خودش می‌گوید تغییر کرده است';

  @override
  String get disclosureChangedLead =>
      'شما نسخهٔ پیشین متن زیر را پذیرفته بودید. بخشی از آن نادرست بود یا تغییر کرده است، پس دوباره نشان داده می‌شود. بخش‌های تازه یا تغییرکرده علامت خورده‌اند.';

  @override
  String get disclosureChangedLabel => 'تازه یا تغییرکرده';

  @override
  String get contactsNewTitle => 'جدید';

  @override
  String get contactsNewGroup => 'گروه جدید';

  @override
  String get contactsNewGroupClosed => 'روی این دستگاه در دسترس نیست';

  @override
  String get contactsNewVoiceRoom => 'اتاق صوتی جدید';

  @override
  String get contactsSearchLabel => 'جست‌وجوی مخاطبان';

  @override
  String get contactsLoadingTitle => 'در حال بارگیری مخاطبان';

  @override
  String get contactsEmptyTitle => 'هنوز مخاطبی نیست';

  @override
  String get contactsEmptyMessage =>
      'کاربران فعال پس از به‌روزرسانی فهرست اینجا نمایش داده می‌شوند.';

  @override
  String get contactsOfflineMessage => 'آفلاین — نمایش مخاطبان ذخیره‌شده';

  @override
  String get contactsLoadMore => 'نمایش مخاطبان بیشتر';

  @override
  String get contactsVerified => 'هویت تأیید شده';

  @override
  String get contactsUnverified => 'هویت تأیید نشده';

  @override
  String get contactsUsernameFallback =>
      'تا احراز هویت و پروفایل رمزنگاری‌شده، نام کاربری سرور نمایش داده می‌شود.';

  @override
  String get contactProfileTitle => 'پروفایل مخاطب';

  @override
  String get contactMessageAction => 'پیام';

  @override
  String get contactMuteAction => 'بی‌صدا';

  @override
  String get contactVerifyAction => 'تأیید شماره امنیتی';

  @override
  String get contactSharedMediaAction => 'رسانه‌ها و فایل‌های مشترک';

  @override
  String get contactClearHistoryAction => 'پاک‌کردن تاریخچه';

  @override
  String get contactBlockAction => 'مسدودکردن';

  @override
  String get contactSensitiveBlocked =>
      'پیام‌رسانی تا تأیید هویت و همه دستگاه‌ها متوقف است.';

  @override
  String get profileEditTitle => 'ویرایش پروفایل';

  @override
  String get profileDisplayNameLabel => 'نام نمایشی';

  @override
  String get profileVisibilityNote =>
      'این پروفایل رمزنگاری‌شده فقط برای مخاطبانی که کلید احرازشده دریافت کنند قابل مشاهده است. اطلاعات شخصی را حداقل نگه دارید.';

  @override
  String get profileAvatarStyleLabel => 'سبک آواتار';

  @override
  String get profileSaveAction => 'ذخیره پروفایل رمزنگاری‌شده';

  @override
  String get profileSavingAction => 'در حال ذخیره…';

  @override
  String get profileTemporaryTransport =>
      'فقط در نسخهٔ توسعه: رمزنگاری و توزیع کلید پروفایل اینجا جایگزین موقت است، نه رمزنگاری واقعی.';

  @override
  String get profileNotBuiltNotice =>
      'این نسخه هنوز نمی‌تواند پروفایل را منتشر کند. نام و عکسی که اینجا انتخاب می‌کنید جایی فرستاده نمی‌شود و مخاطبان شما همان نام کاربری ثبت‌نامتان را می‌بینند.';

  @override
  String get profileSavedMessage => 'پروفایل رمزنگاری‌شده منتشر شد.';

  @override
  String get profileInvalidName => 'نام نمایشی باید بین ۱ تا ۶۴ نویسه باشد.';

  @override
  String get safetyTitle => 'شماره امنیتی';

  @override
  String get safetyInstructions =>
      'این مقادیر را حضوری یا از یک راه مورد اعتماد دیگر مقایسه کنید. سرور نمی‌تواند آن‌ها را تأیید کند.';

  @override
  String get safetyEmojiLabel => 'مقایسه ایموجی';

  @override
  String get safetyNumberLabel => 'مقایسه عددی';

  @override
  String get safetyQrLabel => 'مقدار QR امنیتی';

  @override
  String get safetyOutOfBandCheck =>
      'مقادیر را خارج از این برنامه با این مخاطب مقایسه کردم.';

  @override
  String get safetyConfirmAction => 'تأیید هویت';

  @override
  String get safetyVerifiedState =>
      'تأییدشده — کلید اصلی دقیق با کلید امضای کاربر شما گواهی شده است.';

  @override
  String get safetyUnverifiedState => 'تأییدنشده — پیام‌رسانی متوقف است';

  @override
  String get safetyMasterChangedState =>
      'کلید اصلی تغییر کرده است — تا تأیید خارج از برنامه، کنش‌های حساس مسدودند.';

  @override
  String get safetyInvalidDeviceState =>
      'دستگاه بدون امضا یا نامعتبر — پیام‌ها متوقفند.';

  @override
  String get safetyForkState =>
      'انشعاب دفتر دستگاه شناسایی شد — همه کنش‌های حساس مسدودند.';

  @override
  String get safetyIdentityUnavailableState =>
      'هویت امضاشده معتبر در دسترس نیست.';

  @override
  String get safetyRefreshing =>
      'در حال بررسی هویت، دستگاه‌ها، پیش‌کلیدها و دفتر دستگاه…';

  @override
  String get safetyRetryAction => 'تلاش دوباره';

  @override
  String get safetyConfirmationRequired =>
      'پیش از تأیید، مقایسه خارج از برنامه الزامی است.';

  @override
  String get chatsTitle => 'گفت‌وگوها';

  @override
  String get chatsSearchAction => 'جست‌وجوی گفت‌وگوها';

  @override
  String get chatsSearchHint => 'جست‌وجو در نام‌ها و آخرین پیام';

  @override
  String get chatsClearSearchAction => 'پاک کردن جست‌وجو';

  @override
  String get chatsLoadingTitle => 'در حال بارگذاری گفت‌وگوها';

  @override
  String get chatsErrorTitle => 'گفت‌وگوها در دسترس نیستند';

  @override
  String get chatsErrorMessage => 'فهرست رمزنگاری‌شدهٔ محلی باز نشد.';

  @override
  String get chatsEmptyTitle => 'هنوز گفت‌وگویی نیست';

  @override
  String get chatsEmptyMessage =>
      'یک پیام مستقیم تأییدشده را آغاز کنید. گفت‌وگوها آفلاین روی این دستگاه خوانا می‌مانند.';

  @override
  String get chatsStartAction => 'شروع گفت‌وگو';

  @override
  String get chatsNoSearchResultsTitle => 'چیزی روی این گوشی پیدا نشد';

  @override
  String get chatsDeviceSearchScopeNotice =>
      'فقط پیام‌های ذخیره‌شده روی همین گوشی جست‌وجو می‌شوند. سرور نه آن‌ها را می‌بیند و نه آنچه را جست‌وجو می‌کنید.';

  @override
  String get chatsListSearchScopeNotice =>
      'این فهرست فقط نام‌ها و آخرین پیام را می‌گردد. برای جست‌وجو در تاریخچهٔ یک گفت‌وگو، آن را باز کنید و داخل آن جست‌وجو کنید.';

  @override
  String get chatsDeliveryConnectingNotice => 'در حال اتصال…';

  @override
  String get chatsDeliverySyncingNotice => 'در حال همگام‌سازی…';

  @override
  String get chatsDeliveryWaitingNotice => 'در انتظار اتصال دوباره…';

  @override
  String get chatsOfflineCachedNotice =>
      'آفلاین — گفت‌وگوهای ذخیره‌شده نمایش داده می‌شوند. پیام‌های جدید در صف محلی می‌مانند.';

  @override
  String get chatsNoMessagesPreview => 'هنوز پیامی نیست';

  @override
  String get chatsConversationActionsLabel => 'عملیات گفت‌وگو';

  @override
  String get chatsMuteAction => 'بی‌صدا برای ۸ ساعت';

  @override
  String get chatsUnmuteAction => 'لغو بی‌صدایی';

  @override
  String get chatsMarkReadAction => 'علامت‌گذاری به‌عنوان خوانده‌شده';

  @override
  String get chatsMarkUnreadAction => 'علامت‌گذاری به‌عنوان خوانده‌نشده';

  @override
  String get chatsDeleteAction => 'حذف گفت‌وگو';

  @override
  String get chatsDeleteTitle => 'این گفت‌وگو حذف شود؟';

  @override
  String get chatsDeleteLocalOnlyMessage =>
      'پاک‌کردن گفت‌وگو فقط نمای محلی این دستگاه را حذف می‌کند و محتوای دستگاه‌های دیگر را پاک نمی‌کند.';

  @override
  String chatsItemSemantics(String title, String preview, int unreadCount) {
    return '$title. $preview. $unreadCount پیام خوانده‌نشده.';
  }

  @override
  String get chatTitle => 'گفت‌وگو';

  @override
  String get savedMessagesTitle => 'پیام‌های ذخیره‌شده';

  @override
  String get savedMessagesEmptyTitle => 'هنوز چیزی ذخیره نشده';

  @override
  String get savedMessagesEmptyMessage =>
      'این‌جا گفت‌وگوی شخصی رمزنگاری‌شدهٔ شماست و حضور یا رسید خواندن ندارد.';

  @override
  String get savedMessagesComposerHint => 'یادداشتی برای خودتان بنویسید';

  @override
  String get chatHistoryLoading => 'در حال بارگذاری تاریخچهٔ رمزنگاری‌شده';

  @override
  String get chatHistoryErrorTitle => 'تاریخچه در دسترس نیست';

  @override
  String get chatHistoryErrorMessage =>
      'تاریخچهٔ محلی خوانده نشد؛ سرور نسخه‌ای از آن ندارد.';

  @override
  String get chatEmptyTitle => 'گفت‌وگو را آغاز کنید';

  @override
  String get chatEmptyMessage =>
      'پیام‌ها پیش از ورود به صف ارسال، روی این دستگاه رمزنگاری می‌شوند.';

  @override
  String chatTimelineSemantics(String title) {
    return 'خط زمانی پیام‌های $title';
  }

  @override
  String chatMessageSemantics(String author, String message, String state) {
    return '$author: $message. وضعیت: $state.';
  }

  @override
  String get chatMessageActionsLabel => 'عملیات پیام';

  @override
  String get chatReplyAction => 'پاسخ';

  @override
  String get chatEditAction => 'ویرایش';

  @override
  String get chatForwardAction => 'بازفرستادن';

  @override
  String get chatCopyAction => 'رونوشت';

  @override
  String get chatStarAction => 'ستاره‌دار کردن روی این دستگاه';

  @override
  String get chatUnstarAction => 'برداشتن ستاره';

  @override
  String get chatPinAction => 'پین کردن';

  @override
  String get chatUnpinAction => 'برداشتن پین';

  @override
  String get chatDeleteAction => 'حذف';

  @override
  String get chatDeleteTitle => 'پیام حذف شود؟';

  @override
  String get chatDeleteHonestMessage =>
      '«حذف برای من» نسخهٔ محلی این دستگاه را حذف می‌کند. «حذف برای همه» بهترین تلاش است و نمی‌تواند محتوای دریافت و رمزگشایی‌شدهٔ دستگاه دیگر را پاک کند.';

  @override
  String get chatDeleteForMeAction => 'حذف برای من';

  @override
  String get chatDeleteForEveryoneAction => 'حذف برای همه';

  @override
  String get chatCancelAction => 'لغو';

  @override
  String get chatDeletedMessage => 'پیام حذف شده است';

  @override
  String get chatUnsupportedMessage =>
      'این پیام به نسخهٔ جدیدتری از پروتکل نیاز دارد؛ رکورد رمزنگاری‌شده نگه داشته شد.';

  @override
  String get chatSystemMessage => 'به‌روزرسانی گفت‌وگو';

  @override
  String get chatEditedLabel => 'ویرایش‌شده';

  @override
  String get chatTimestampSkewed =>
      'ساعت فرستنده دقیق به نظر نمی‌رسد؛ این زمان فقط نمایشی است.';

  @override
  String get chatReplyQuote => 'پیام پاسخ‌داده‌شده';

  @override
  String chatReactionSemantics(String emoji, int count) {
    return 'واکنش $emoji، $count نفر';
  }

  @override
  String get chatReactionSelectorLabel => 'انتخاب واکنش';

  @override
  String chatReactionAddAction(String emoji) {
    return 'واکنش با $emoji';
  }

  @override
  String chatReactionRemoveAction(String emoji) {
    return 'برداشتن واکنش $emoji شما';
  }

  @override
  String get chatMoreReactionsAction => 'شکلک‌های بیشتر';

  @override
  String get chatRetrySendAction =>
      'تلاش دوباره به‌عنوان ارسال رمزنگاری‌شدهٔ جدید';

  @override
  String get chatUnreadDivider => 'پیام‌های خوانده‌نشده';

  @override
  String get chatLoadingOlder => 'در حال بارگذاری پیام‌های قدیمی‌تر';

  @override
  String get chatLoadOlderAction => 'بارگذاری پیام‌های قدیمی‌تر';

  @override
  String get chatOlderErrorAction =>
      'بارگذاری پیام‌های قدیمی‌تر ناموفق بود — تلاش دوباره';

  @override
  String get chatBeginningOfHistory => 'آغاز تاریخچهٔ محلی';

  @override
  String get chatJumpToLatestAction => 'رفتن به جدیدترین پیام';

  @override
  String get chatComposerHint => 'پیام';

  @override
  String get chatAttachAction => 'پیوست';

  @override
  String get chatEmojiAction => 'درج شکلک';

  @override
  String get chatEmojiPanelCloseAction => 'بستن پنل شکلک';

  @override
  String get emojiPickerLabel => 'انتخابگر شکلک';

  @override
  String get emojiPickerSearchHint => 'جست‌وجوی شکلک';

  @override
  String get chatSendAction => 'ارسال پیام رمزنگاری‌شده';

  @override
  String get chatSaveEditAction => 'ذخیرهٔ ویرایش رمزنگاری‌شده';

  @override
  String get chatCancelContextAction => 'لغو پاسخ یا ویرایش';

  @override
  String get chatEditingMessage => 'در حال ویرایش پیام';

  @override
  String chatReplyingTo(String author) {
    return 'پاسخ به $author';
  }

  @override
  String get chatOfflineQueueNotice =>
      'آفلاین — پیام رمزنگاری‌شده تا دسترسی به سرور در صف محلی می‌ماند.';

  @override
  String get chatWithheldUnverifiedIdentity =>
      'ارسال متوقف است: پیش از ارسال، هویت را خارج از برنامه تأیید کنید.';

  @override
  String get chatWithheldUnverifiedDevice =>
      'ارسال متوقف است: دستگاه بدون امضا یا نامعتبر نمی‌تواند پیام بگیرد.';

  @override
  String get chatWithheldMasterChanged =>
      'ارسال متوقف است: کلید اصلی مخاطب تغییر کرده و باید دوباره تأیید شود.';

  @override
  String get chatWithheldLogFork =>
      'ارسال متوقف است: انشعاب دفتر دستگاه احتمال دوگانگی سرور را نشان می‌دهد.';

  @override
  String get chatWithheldPq =>
      'ارسال متوقف است: کلید پساکوانتومی ML-KEM در دسترس نیست؛ تنزل امنیتی انجام نمی‌شود.';

  @override
  String chatPinnedBanner(int count) {
    return '$count پیام پین‌شده';
  }

  @override
  String get chatPinnedExpandAction => 'مشاهدهٔ همه';

  @override
  String get chatPinnedMessagesTitle => 'پیام‌های پین‌شده';

  @override
  String get chatTypingStatus =>
      'در حال نوشتن… سیگنال رمزنگاری‌شده ممکن است با تأخیر برسد';

  @override
  String get chatSearchAction => 'جست‌وجو در گفت‌وگو';

  @override
  String get chatSearchInputLabel => 'جست‌وجوی پیام‌های محلی';

  @override
  String get chatSearchEmptyQueryTitle => 'جست‌وجوی تاریخچهٔ این دستگاه';

  @override
  String get chatMoreAction => 'عملیات بیشتر گفت‌وگو';

  @override
  String get chatYouAuthor => 'شما';

  @override
  String get chatAttachmentsUnavailable => 'باز کردن یا ذخیرهٔ فایل تأییدشده';

  @override
  String get attachmentChoosePrompt =>
      'رسانه یا فایل رمزنگاری‌شده را انتخاب کنید.';

  @override
  String get attachmentsNotBuiltNotice =>
      'پیوست فایل هنوز ساخته نشده است. در این نسخه نمی‌توان چیزی به پیام پیوست کرد.';

  @override
  String get attachmentPhotoOption => 'عکس یا تصویر';

  @override
  String get attachmentFileOption => 'فایل';

  @override
  String get attachmentCameraOption => 'دوربین';

  @override
  String get attachmentImageLabel => 'تصویر رمزنگاری‌شده';

  @override
  String get attachmentFileLabel => 'پیوست رمزنگاری‌شده';

  @override
  String get attachmentOpenHint => 'پس از تأیید محلی باز کنید';

  @override
  String get attachmentQueuedState => 'پیوست در صف است';

  @override
  String get attachmentDownloadingState => 'در حال دریافت پیوست';

  @override
  String get attachmentVerifyingState => 'در حال تأیید پیوست';

  @override
  String get attachmentReadyState => 'پیوست تأییدشده';

  @override
  String get attachmentExpiredState => 'پیوست منقضی شده است';

  @override
  String get attachmentCancelledState => 'پیوست لغو شده است';

  @override
  String get attachmentQuotaState => 'سهمیهٔ پیوست تمام شده است';

  @override
  String get attachmentUnsupportedState => 'پیوست پشتیبانی نمی‌شود';

  @override
  String get attachmentCorruptState => 'پیوست خراب است';

  @override
  String get attachmentFailedState => 'پیوست ناموفق بود';

  @override
  String attachmentDetails(String mimeType, int size) {
    return '$mimeType · $size بایت';
  }

  @override
  String get chatActionFailedMessage =>
      'عملیات انجام نشد؛ هیچ تضمین امنیتی تضعیف نشده است.';

  @override
  String get chatStateLocalOnly => 'فقط محلی ذخیره شد';

  @override
  String get chatStateQueued => 'در صف آفلاین';

  @override
  String get chatStateEncrypting => 'در حال رمزنگاری';

  @override
  String get chatStateSending => 'در حال ارسال به سرور';

  @override
  String get chatStateAccepted => 'پذیرفته‌شده توسط رلهٔ سرور';

  @override
  String get chatStateDelivered => 'تحویل پایدار به دستگاه گیرنده';

  @override
  String get chatStateRead => 'رسید خواندن دریافت شد';

  @override
  String get chatStateFailed => 'ارسال ناموفق';

  @override
  String get chatStateReceived => 'دریافت‌شده';

  @override
  String get groupProductionUnavailableTitle =>
      'گروه‌های عملیاتی در دسترس نیستند';

  @override
  String get groupProductionUnavailableMessage =>
      'پروفایل MLS پساکوانتومی هنوز پشت دروازهٔ امنیتی است. این ساخت نمی‌تواند گروه بسازد، KeyPackage تولید کند یا متن رمز گروهی بفرستد.';

  @override
  String get groupExperimentalWithheldTitle =>
      'پیام‌رسانی گروهی روی این دستگاه در دسترس نیست';

  @override
  String get groupExperimentalWithheldMessage =>
      'رمزنگاری گروهی آزمایشی روی گوشی‌های ARM ۶۴بیتی آزمایش شده است و این دستگاه از پردازندهٔ دیگری استفاده می‌کند. به‌جای اجرای آزمایش‌نشده، گفت‌وگوهای گروهی اینجا خاموش است: هیچ کلیدی برای شما منتشر نمی‌شود و هیچ پیام گروهی به این دستگاه نمی‌رسد. پیام‌های مستقیم بی‌تأثیر می‌مانند.';

  @override
  String get groupDevelopmentPreviewBanner =>
      'فقط پیش‌نمایش توسعه — هیچ متن رمز گروهی عملیاتی ارسال نمی‌شود';

  @override
  String get groupExperimentalBanner =>
      'رمزنگاری گروهی آزمایشی — بازبینی‌نشده و غیراستاندارد. یک به‌روزرسانی ممکن است این گروه‌ها را بازنشانی کند و پیام‌هایشان را حذف کند.';

  @override
  String get groupCreateTitle => 'ساخت گروه';

  @override
  String get groupPickMembersTitle => 'انتخاب اعضا';

  @override
  String get groupDetailsTitle => 'مشخصات گروه';

  @override
  String get groupNextAction => 'بعدی';

  @override
  String get groupBackAction => 'بازگشت';

  @override
  String get groupCreateAction => 'ساخت';

  @override
  String get groupCreatingState => 'در حال ساخت پیش‌نمایش محلی گروه…';

  @override
  String get groupCreateFailed => 'گروه ساخته نشد. چیزی ارسال نشد.';

  @override
  String get groupSelectMemberMessage => 'حداقل یک عضو انتخاب کنید.';

  @override
  String get groupMemberLimitMessage =>
      'گروه با احتساب شما حداکثر ۵۰ عضو دارد.';

  @override
  String get groupNameLabel => 'نام گروه';

  @override
  String get groupDescriptionLabel => 'توضیح (اختیاری)';

  @override
  String get groupPhotoAction => 'انتخاب عکس رمزگذاری‌شده';

  @override
  String get groupPhotoSelected => 'یک عکس پیش‌نمایش محلی انتخاب شده است';

  @override
  String get groupSearchMembersLabel => 'جست‌وجوی اعضا';

  @override
  String groupSelectedCount(int count) {
    return '$count انتخاب‌شده';
  }

  @override
  String groupMemberCount(int count) {
    return '$count عضو';
  }

  @override
  String get groupInfoTitle => 'اطلاعات گروه';

  @override
  String get groupEditTitle => 'ویرایش گروه';

  @override
  String get groupEditAction => 'ویرایش';

  @override
  String get groupAddMembersAction => 'افزودن اعضا';

  @override
  String get groupLeaveAction => 'ترک گروه';

  @override
  String get groupRemoveAction => 'حذف از گروه';

  @override
  String get groupPromoteAction => 'مدیر کردن';

  @override
  String get groupDemoteAction => 'عضو کردن';

  @override
  String get groupTransferOwnerAction => 'انتقال مالکیت';

  @override
  String get groupRoleOwner => 'مالک';

  @override
  String get groupRoleAdmin => 'مدیر';

  @override
  String get groupRoleMember => 'عضو';

  @override
  String get groupInvitePolicyLabel => 'چه کسانی می‌توانند عضو بیفزایند';

  @override
  String get groupInviteOwnerOnly => 'فقط مالک';

  @override
  String get groupInviteAdmins => 'مالک و مدیران';

  @override
  String get groupInviteEveryone => 'همهٔ اعضا';

  @override
  String get groupHistorySharingLabel => 'نمایش تاریخچهٔ موجود به اعضای جدید';

  @override
  String get groupHistorySharingNote =>
      'اگر روشن باشد، دستگاه یکی از اعضای موجود عمداً پیام‌های قبلی را دوباره با عضو جدید به اشتراک می‌گذارد. سرور نمی‌تواند این تاریخچه را بازسازی یا ارسال کند و ممکن است دستگاه منبع فقط بخشی از تاریخچه را داشته باشد.';

  @override
  String get groupSaveAction => 'ذخیره';

  @override
  String get groupCancelAction => 'انصراف';

  @override
  String get groupPermissionChanged =>
      'نقش شما تغییر کرده و دیگر نمی‌توانید این تنظیمات را ذخیره کنید.';

  @override
  String get groupMembershipUpdatingState =>
      'عضویت در حال تغییر است. ارسال و تغییر اعضا موقتاً متوقف شده است.';

  @override
  String get groupRemovedState =>
      'شما حذف شده‌اید. محتوای قبلی این دستگاه خواندنی می‌ماند، اما دوره‌های آیندهٔ گروه در دسترس نیست.';

  @override
  String get groupLeftState =>
      'شما گروه را ترک کرده‌اید. این نسخه فقط خواندنی است.';

  @override
  String get groupQueueGapState =>
      'ممکن است شکاف صندوق پستی یک Commit از MLS را پنهان کرده باشد. پیش از ارسال، این دستگاه باید حذف و با Welcome تازه دوباره افزوده شود.';

  @override
  String get groupForkState =>
      'Commitهای هم‌زمان MLS قرنطینه شدند. برنامه هیچ شاخه‌ای را خودسرانه انتخاب نمی‌کند.';

  @override
  String get groupControlQuarantineState =>
      'یک کنترل نامعتبر یا بدون مجوز گروه قرنطینه شد.';

  @override
  String get groupReadOnlyLabel => 'گروه فقط خواندنی';

  @override
  String get groupMessageHint => 'پیام به گروه';

  @override
  String get groupSendFailed => 'پیام ذخیره نشد. چیزی ارسال نشد.';

  @override
  String get groupMuteAction => 'بی‌صدا';

  @override
  String get groupSearchChatAction => 'جست‌وجو در گفتگو';

  @override
  String get groupSharedMediaAction => 'رسانه‌های مشترک';

  @override
  String get groupNoDescription => 'بدون توضیح';

  @override
  String get groupMembersSection => 'اعضا';

  @override
  String get groupVerifiedMember => 'هویت تأییدشده';

  @override
  String get groupConfirmRemoveTitle => 'عضو حذف شود؟';

  @override
  String get groupConfirmRemoveBody =>
      'حذف عضو دورهٔ گروه را جلو می‌برد و دسترسی او به پیام‌های آینده را قطع می‌کند؛ محتوای از قبل دریافت‌شده پاک نمی‌شود.';

  @override
  String get groupConfirmLeaveTitle => 'گروه ترک شود؟';

  @override
  String get groupConfirmLeaveBody =>
      'دسترسی به دوره‌های آیندهٔ گروه را از دست می‌دهید. محتوای ذخیره‌شده روی این دستگاه خواندنی می‌ماند.';

  @override
  String get groupOwnerMustTransfer => 'پیش از ترک گروه، مالکیت را منتقل کنید.';

  @override
  String get groupActionFailed =>
      'تغییر گروه ثبت نشد. وضعیت قبلی گروه بدون تغییر ماند.';

  @override
  String get groupMemberPickerEmpty => 'مخاطب واجد شرایطی پیدا نشد';

  @override
  String get groupWithheldUpdating =>
      'ارسال پیام متوقف است: عضویت در حال تغییر است.';

  @override
  String get groupWithheldRemoved =>
      'ارسال پیام متوقف است: این گروه روی این دستگاه فقط خواندنی است.';

  @override
  String get groupWithheldQueueGap =>
      'ارسال پیام متوقف است: پس از شکاف صندوق پستی باید با Welcome تازه دوباره بپیوندید.';

  @override
  String get groupWithheldConflict =>
      'ارسال پیام متوقف است: تعارض کنترل گروه قرنطینه شده است.';

  @override
  String get sustainedNotificationTitle => 'در پس‌زمینه باز نگه داشته شده';

  @override
  String get sustainedChannelName => 'اجرا در پس‌زمینه';

  @override
  String get sustainedChannelDescription =>
      'تا وقتی برنامه برای دریافت پیام باز نگه داشته می‌شود نمایش داده می‌شود.';

  @override
  String get settingsSustainedTitle => 'دریافت هنگام بسته بودن';

  @override
  String get settingsSustainedOff =>
      'خاموش. گوشی شما بر اساس زمان‌بندی خودش دنبال پیام می‌گردد؛ کند است و بارها اصلاً انجام نمی‌شود.';

  @override
  String get settingsSustainedHolding =>
      'روشن. برنامه در پس‌زمینه باز نگه داشته می‌شود و تا وقتی روشن است یک اعلان دائمی روی گوشی شما دیده می‌شود.';

  @override
  String get settingsSustainedAlertsWithheld =>
      'روشن، اما اعلان‌ها خاموش‌اند؛ پس هیچ چیز رسیدن پیام را به شما نمی‌گوید.';

  @override
  String get settingsSustainedExemptionWithdrawn =>
      'روشن، اما گوشی شما اجازهٔ کار در حالت ذخیرهٔ باتری را پس گرفته است.';

  @override
  String get settingsSustainedStopped =>
      'روشن، اما همین حالا در حال اجرا نیست.';

  @override
  String get settingsSustainedUnavailable => 'در این نسخه در دسترس نیست.';

  @override
  String get settingsSustainedWithheld =>
      'در این نسخه ارائه نمی‌شود. هنوز روی گوشی‌هایی مثل گوشی شما آزمایش نشده است.';

  @override
  String get sustainedTitle => 'دریافت هنگام بسته بودن';

  @override
  String get sustainedWhatItDoes =>
      'به‌طور معمول وقتی از برنامه بیرون می‌روید گوشی آن را متوقف می‌کند و دست‌بالا هر پانزده دقیقه اجازه می‌دهد دنبال پیام تازه بگردد. با روشن کردن این گزینه، برنامه در پس‌زمینه باز نگه داشته می‌شود تا پیام بدون انتظار برای آن بازه به شما برسد. اینکه روی گوشی شما چقدر طول می‌کشد، اندازه‌گیری نشده است.';

  @override
  String get sustainedWhatItCosts =>
      'باتری بیشتری مصرف می‌شود، چون برنامه متصل می‌ماند. یک اعلان دائمی روی گوشی شما می‌گذارد که می‌گوید برنامه در حال اجراست: هر کسی که قفل گوشی شما را باز کند و نگاه کند آن را می‌بیند و تا وقتی این گزینه را خاموش نکنید آنجا می‌ماند. روی صفحهٔ قفل پنهان است.';

  @override
  String get sustainedWhatItCannotPromise =>
      'گوشی شما اجازه دارد هر لحظه آن را متوقف کند و چیزی هم نمی‌گوید. اگر برنامه را به‌اجبار متوقف کنید (force stop) یا مصرف باتری آن را محدود کنید، به‌کلی متوقف می‌شود. این برنامه نمی‌تواند قول بدهد که کار می‌کند؛ فقط قول می‌دهد هر وقت ببیند کار نمی‌کند، همین‌جا به شما بگوید.';

  @override
  String get sustainedNeedsTitle => 'آنچه گوشی از شما می‌خواهد';

  @override
  String get sustainedNeedsAlerts =>
      'اجازهٔ نمایش اعلان. بدون آن ممکن است پیامی برسد و هیچ چیز به شما نگوید.';

  @override
  String get sustainedNeedsExemption =>
      'اجازهٔ ادامهٔ کار در حالتی که گوشی باتری ذخیره می‌کند. گوشی خودش مستقیم از شما می‌پرسد.';

  @override
  String get sustainedNeedsVendor =>
      'روی گوشی‌های سامسونگ و شیائومی یک کار دیگر هم لازم است: گوشی برنامه‌های کم‌استفاده را خودش به خواب می‌برد و این برنامه باید از آن مستثنا شود. فقط شما می‌توانید این کار را انجام دهید و این برنامه نمی‌تواند بررسی کند که انجامش داده‌اید یا نه.';

  @override
  String get sustainedVendorAction => 'باز کردن تنظیمات گوشی من';

  @override
  String get sustainedTurnOn => 'روشن کردن';

  @override
  String get sustainedTurnOff => 'خاموش کردن';

  @override
  String get sustainedStatusOff =>
      'خاموش. چیزی در حال اجرا نیست و چیزی روی گوشی شما نمایش داده نمی‌شود.';

  @override
  String get sustainedStatusHolding => 'روشن. برنامه باز نگه داشته می‌شود.';

  @override
  String get sustainedStatusAlertsWithheld =>
      'اعلان‌های این برنامه خاموش است، پس این گزینه متوقف شد. اعلان‌ها را روشن کنید تا دوباره شروع شود.';

  @override
  String get sustainedStatusExemptionWithdrawn =>
      'گوشی شما اجازهٔ کار در حالت ذخیرهٔ باتری را پس گرفته است، پس این گزینه متوقف شد. این اتفاق می‌تواند پس از به‌روزرسانی گوشی خودبه‌خود بیفتد. دوباره روشن کنید تا اجازه یک بار دیگر خواسته شود.';

  @override
  String get sustainedStatusStopped =>
      'در این لحظه در حال اجرا نیست. ممکن است گوشی شما آن را متوقف کرده باشد.';

  @override
  String get sustainedStatusUnavailable => 'در این نسخه در دسترس نیست.';

  @override
  String get sustainedStatusWithheld =>
      'این نسخه این گزینه را روشن نمی‌کند. کاری که انجام می‌دهد روی گوشی‌هایی مثل گوشی شما اندازه‌گیری نشده است، و ارائهٔ آن پیش از این کار یعنی قول دادن چیزی که کسی بررسی‌اش نکرده است. چیزی در حال اجرا نیست و چیزی روی گوشی شما نمایش داده نمی‌شود.';

  @override
  String get sustainedRefusedAlerts =>
      'روشن نشد: اعلان‌های این برنامه هنوز خاموش است.';

  @override
  String get sustainedRefusedExemption =>
      'روشن نشد: گوشی اجازهٔ کار در حالت ذخیرهٔ باتری را نداد.';

  @override
  String get sustainedRefusedPlatform =>
      'روشن نشد: گوشی اجازه نداد برنامه در حال اجرا بماند. برخی گوشی‌ها تا وقتی برنامه از فهرست «به خواب بردن برنامه‌ها» مستثنا نشود همین کار را می‌کنند.';

  @override
  String get sustainedRefusedNotRecorded =>
      'روشن نشد: این انتخاب روی این گوشی ذخیره نشد و پس از راه‌اندازی مجدد باقی نمی‌ماند.';

  @override
  String get sustainedRefusedUnavailable => 'در این نسخه در دسترس نیست.';

  @override
  String get sustainedRefusedWithheld =>
      'روشن نشد: این نسخه هنوز این گزینه را ارائه نمی‌دهد.';

  @override
  String settingsSignedInAs(String username) {
    return 'وارد‌شده با $username';
  }

  @override
  String get settingsProfileSummary =>
      'نام نمایشی و عکس شما، و آنچه دیگران می‌بینند';

  @override
  String get settingsSavedMessagesSummary =>
      'یادداشت‌های شخصی، ذخیره‌شده روی همین گوشی';

  @override
  String get settingsSecurityTitle => 'امنیت و بازیابی';

  @override
  String get settingsSecuritySummary =>
      'جایگزینی رمز بازیابی و مرور مخاطبان تأیید‌شده';

  @override
  String get settingsAppearanceSummary => 'پوسته و زبان، فقط روی همین گوشی';

  @override
  String get settingsAboutTitle => 'درباره';

  @override
  String get settingsAboutSummary =>
      'نسخه، ماهیت این نسخه، و گزارشی که می‌توانید کپی کنید';

  @override
  String get settingsLogOutTitle => 'خروج از حساب';

  @override
  String get settingsLogOutConfirmTitle => 'از این دستگاه خارج می‌شوید؟';

  @override
  String get settingsLogOutConfirmBody =>
      'هر چیزی که این گوشی نگه داشته پاک می‌شود: پیام‌ها، مخاطبان، و کلیدهایی که آن‌ها را رمزگشایی می‌کنند. سرور هیچ نسخه‌ای از تاریخچهٔ شما نگه نمی‌دارد، پس با ورود دوباره چیزی بازنمی‌گردد — تنها دستگاه دیگری که هنوز تاریخچه را دارد می‌تواند آن را برای شما بفرستد. رمز بازیابی هویت شما را بازمی‌گرداند، هرگز پیام‌ها را.';

  @override
  String get settingsLogOutConfirmAction => 'خروج و پاک‌سازی';

  @override
  String get settingsCancelAction => 'انصراف';

  @override
  String get settingsEraseAccountTitle => 'پاک‌سازی این حساب';

  @override
  String get settingsEraseAccountSummary =>
      'هر چه سرور دربارهٔ این حساب نگه می‌دارد حذف می‌شود. این کار برگشت‌پذیر نیست.';

  @override
  String get eraseAccountConfirmTitle => 'این حساب پاک شود؟';

  @override
  String get eraseAccountServerScope =>
      'هر چه سرور دربارهٔ این حساب نگه می‌دارد حذف می‌شود: دستگاه‌های شما، کلیدهایتان، هویت منتشرشده‌تان، نمایه‌تان، و هر پیامی که هنوز منتظر رسیدن به شماست.';

  @override
  String get eraseAccountPeerCopies =>
      'نسخه‌هایی که دیگران دارند پاک نمی‌شوند. هر پیامی که فرستاده‌اید روی گوشی گیرنده رمزگشایی شده و همان‌جا ذخیره است. هیچ بخشی از این کار به دستگاه دیگری نمی‌رسد.';

  @override
  String eraseAccountAttachments(int days) {
    return 'فایل‌هایی که بارگذاری کرده‌اید تا $days روز روی سرور می‌مانند، تا وقتی بازهٔ نگهداری تمام شود. هیچ چیزِ ذخیره‌شده کنار یک فایل نام حساب شما را ندارد، پس مجموعه‌ای از آن‌ها وجود ندارد که این کار بتواند حذفش کند.';
  }

  @override
  String get eraseAccountUsernameFreed =>
      'نام کاربری شما بی‌درنگ آزاد می‌شود. شخص دیگری می‌تواند آن را ثبت کند.';

  @override
  String get eraseAccountPasswordLabel => 'گذرواژهٔ شما';

  @override
  String get eraseAccountPasswordPurpose =>
      'گذرواژه فقط با همین درخواست فرستاده می‌شود و هیچ‌جا ذخیره نمی‌شود.';

  @override
  String get eraseAccountAction => 'پاک‌سازی حساب';

  @override
  String get eraseAccountWorkingAction => 'در حال پاک‌سازی…';

  @override
  String eraseAccountWrongPassword(int used, int allowed) {
    return 'گذرواژه نادرست است. $used تلاش از $allowed تلاش مصرف شد. پس از $allowed تلاش نادرست، این نام کاربری پانزده دقیقه قفل می‌شود — هم اینجا و هم در صفحهٔ ورود، روی همهٔ دستگاه‌ها.';
  }

  @override
  String eraseAccountThrottled(String wait) {
    return 'تلاش بیش از حد. $wait دیگر دوباره تلاش کنید.';
  }

  @override
  String get eraseAccountThrottledUnknownWait =>
      'تلاش بیش از حد. بعداً دوباره تلاش کنید.';

  @override
  String eraseAccountWaitMinutes(int minutes) {
    return '$minutes دقیقه';
  }

  @override
  String eraseAccountWaitSeconds(int seconds) {
    return '$seconds ثانیه';
  }

  @override
  String get appearanceTitle => 'ظاهر';

  @override
  String get appearanceLocalOnlyNotice =>
      'این دو تنظیم روی همین گوشی می‌مانند. جایی فرستاده نمی‌شوند و کسی دیگر آن‌ها را نمی‌بیند.';

  @override
  String get appearanceThemeSection => 'پوسته';

  @override
  String get appearanceThemeSystem => 'مطابق گوشی';

  @override
  String get appearanceThemeLight => 'روشن';

  @override
  String get appearanceThemeDark => 'تیره';

  @override
  String get appearanceContrastNotice =>
      'کنتراست بالا از تنظیمات دسترس‌پذیری گوشی پیروی می‌کند و کلیدی در اینجا ندارد.';

  @override
  String get appearanceLanguageSection => 'زبان';

  @override
  String get appearanceLanguageSystem => 'مطابق گوشی';

  @override
  String get appearanceLanguageEnglish => 'English';

  @override
  String get appearanceLanguagePersian => 'فارسی';

  @override
  String get appearanceNotStoredNotice =>
      'این گوشی نتوانست این انتخاب را ذخیره کند. همین حالا اعمال می‌شود و با راه‌اندازی دوبارهٔ برنامه دوباره از گوشی پیروی می‌کند.';

  @override
  String get securitySettingsTitle => 'امنیت و بازیابی';

  @override
  String get securityRecoveryTitle => 'رمز بازیابی';

  @override
  String get securityRecoveryBody =>
      'رمز بازیابی فقط یک بار، هنگام ساخته شدن، نشان داده می‌شود و این برنامه هرگز نسخه‌ای از آن نگه نمی‌دارد — پس دوباره قابل نمایش نیست. اگر رمز خود را گم کرده‌اید یا ممکن است کس دیگری آن را دیده باشد، اینجا یکی تازه بسازید. سرور فقط یک نسخهٔ غیرقابل‌خواندن از هویت شما را نگه می‌دارد، هرگز پیام‌های شما را.';

  @override
  String get securityRecoveryAction => 'ساخت رمز بازیابی تازه';

  @override
  String get securitySafetyNumbersTitle => 'شماره‌های ایمنی';

  @override
  String get securitySafetyNumbersSummary =>
      'کدام مخاطبان را حضوری بررسی کرده‌اید و کدام را نه';

  @override
  String get safetyNumbersReviewBody =>
      'برای مقایسهٔ شمارهٔ ایمنی حضوری یا از راهی که به آن اعتماد دارید، مخاطب را باز کنید. تا آن زمان، پیام‌رسانی با او متوقف می‌ماند.';

  @override
  String get recoveryRotationTitle => 'رمز بازیابی تازه';

  @override
  String get recoveryRotationExplain =>
      'این کار برای همان هویتی که دارید رمزی تازه می‌سازد. مخاطبان شما تأیید‌شده می‌مانند و دستگاه‌های دیگرتان متصل می‌مانند — تنها رمزی که پشتیبان هویت شما را باز می‌کند عوض می‌شود.';

  @override
  String get recoveryRotationCost =>
      'رمزی که اکنون دارید به محض ساخته شدن رمز تازه از کار می‌افتد. پیش از خروج از این صفحه رمز تازه را یادداشت کنید: فقط یک بار نشان داده می‌شود و این برنامه نسخه‌ای از آن نگه نمی‌دارد.';

  @override
  String get recoveryRotationNoHistoryNotice =>
      'رمز بازیابی هویت شما را بازمی‌گرداند، نه آنچه گفته شده است. تاریخچهٔ پیام‌ها فقط روی دستگاه‌های شماست و هیچ جای دیگر.';

  @override
  String get recoveryRotationStartAction => 'ساخت رمز تازه';

  @override
  String get recoveryRotationWorking => 'در حال ساخت رمز تازه…';

  @override
  String get recoveryRotationDoneTitle => 'همین حالا این را یادداشت کنید';

  @override
  String get recoveryRotationShownOnce =>
      'این تنها باری است که این رمز نشان داده می‌شود. رمز قبلی دیگر کار نمی‌کند.';

  @override
  String get recoveryRotationScreenshotNotice =>
      'در این صفحه عکس گرفتن از صفحه مسدود است و نسخهٔ کپی‌شده پس از یک دقیقه از حافظه پاک می‌شود.';

  @override
  String get recoveryRotationCopyAction => 'کپی رمز';

  @override
  String get recoveryRotationCopiedMessage =>
      'کپی شد. تا یک دقیقهٔ دیگر پاک می‌شود.';

  @override
  String get recoveryRotationCopyUnavailable =>
      'این نسخه نمی‌تواند از حافظهٔ موقت به شکل ایمن استفاده کند، پس کپی خاموش است. رمز را یادداشت کنید.';

  @override
  String get recoveryRotationFinishAction => 'یادداشتش کردم';

  @override
  String get recoveryRotationFailedTitle => 'چیزی تغییر نکرد';

  @override
  String get recoveryRotationFailedBody =>
      'رمز تازه روی سرور ذخیره نشد، پس رمز بازیابی فعلی شما همچنان کار می‌کند. وقتی اتصال داشتید دوباره تلاش کنید.';

  @override
  String get recoveryRotationUnavailableBody =>
      'این دستگاه هویت کامل‌شده‌ای برای محافظت ندارد، پس چیزی برای جایگزینی نیست. ابتدا راه‌اندازی رمزنگاری را کامل کنید.';

  @override
  String get aboutVersionLabel => 'نسخه';

  @override
  String get aboutDisclosureLabel => 'ویرایش بیانیه';

  @override
  String get aboutLocalOnlyNotice =>
      'هر چیزی در این صفحه از همین گوشی خوانده شده است. چیزی دریافت و چیزی ارسال نشده است.';

  @override
  String get diagnosticsTitle => 'گزارش عیب‌یابی';

  @override
  String get diagnosticsSummary =>
      'یک گزارش فنی کوتاه که می‌توانید کپی کنید و برای گردانندهٔ سرورتان بفرستید';

  @override
  String get diagnosticsExplain =>
      'این تمام محتوای گزارش است، دقیقاً همان‌گونه که کپی می‌شود. هیچ پیام، نام، نشانی، کلید یا شناسه‌ای در آن نیست — تنها تنظیمات، وضعیت‌ها و شمارش‌های تقریبی.';

  @override
  String get diagnosticsNothingSentNotice =>
      'کپی کردن آن را در حافظهٔ موقت همین گوشی می‌گذارد. برنامه آن را جایی نمی‌فرستد؛ اینکه بعد کجا برود انتخاب شماست.';

  @override
  String get diagnosticsLoadingTitle => 'در حال خواندن این دستگاه…';

  @override
  String get diagnosticsCopyAction => 'کپی گزارش';

  @override
  String get diagnosticsCopiedMessage => 'گزارش کپی شد.';

  @override
  String get diagnosticsCopyFailed =>
      'این گوشی اجازه نداد برنامه از حافظهٔ موقت استفاده کند.';

  @override
  String get diagnosticsRefreshAction => 'خواندن دوباره';

  @override
  String chatSearchTruncatedNotice(int shown) {
    return 'نمایش $shown مورد نخست. برای محدودتر شدن، بیشتر از متن پیام را بنویسید.';
  }

  @override
  String chatSearchResultCount(int count) {
    return '$count مورد روی این گوشی';
  }

  @override
  String get chatClearHistoryTitle => 'این گفتگو پاک شود؟';

  @override
  String get chatClearHistoryBody =>
      'همهٔ پیام‌های این گفتگو از این گوشی حذف می‌شود و دیگر اینجا بازنمی‌گردد. طرف مقابل نسخهٔ خود را نگه می‌دارد و دستگاه‌های دیگر شما هم نسخهٔ خود را.';

  @override
  String get chatClearHistoryAction => 'پاک کردن روی این گوشی';

  @override
  String get linkedDevicesRefreshAction => 'تازه‌سازی';

  @override
  String get linkedDevicesLabelsEncrypted =>
      'نام دستگاه‌ها روی این گوشی رمزنگاری شده است';

  @override
  String get linkedDevicesLoadingTitle => 'در حال بارگذاری دستگاه‌ها';

  @override
  String get linkedDevicesUnavailableTitle => 'فهرست دستگاه‌ها در دسترس نیست';

  @override
  String get linkedDevicesUnavailableMessage =>
      'این دستگاه نتوانست فهرست را بخواند. اتصال خود را بررسی کنید و دوباره تلاش کنید.';

  @override
  String get linkedDevicesEmptyTitle => 'دستگاه دیگری نیست';

  @override
  String get linkedDevicesThisDevice => 'همین دستگاه';

  @override
  String get linkedDevicesUnnamed => 'دستگاه بدون نام';

  @override
  String get linkedDevicesCurrentSubtitle => 'دستگاهی که اکنون استفاده می‌کنید';

  @override
  String linkedDevicesAdded(String date) {
    return 'افزوده‌شده: $date';
  }

  @override
  String get linkedDevicesRenameAction => 'تغییر نام';

  @override
  String get linkedDevicesRemoveAction => 'حذف';

  @override
  String get linkedDevicesRenameTitle => 'تغییر نام دستگاه';

  @override
  String get linkedDevicesRenameLabel => 'نام دستگاه';

  @override
  String get linkedDevicesSaveAction => 'ذخیره';

  @override
  String get linkedDevicesRemoveTitle => 'این دستگاه حذف شود؟';

  @override
  String get linkedDevicesRemoveSelfTitle =>
      'دستگاهی که استفاده می‌کنید حذف شود؟';

  @override
  String get linkedDevicesRemoveBody =>
      'آن دستگاه دیگر نمی‌تواند پیام‌های تازه را بخواند و این کار بازگشت‌پذیر نیست. هر چه روی آن است تا زمان خروج یا پاک‌سازی همانجا می‌ماند.';

  @override
  String get linkedDevicesRemoveSelfBody =>
      'این گوشی از حساب خارج می‌شود و هر چه روی آن است پاک می‌شود، از جمله پیام‌ها و کلیدهایی که آن‌ها را رمزگشایی می‌کنند. این کار بازگشت‌پذیر نیست.';

  @override
  String get linkedDevicesAddTitle => 'افزودن دستگاه دیگر';

  @override
  String get linkedDevicesAddBody =>
      'برنامه را روی دستگاه دیگر نصب کنید، همانجا وارد شوید و وقتی پرسید، رمز بازیابی خود را وارد کنید. پس از امضا شدن، در این فهرست دیده می‌شود. پس از آن این گوشی را متصل نگه دارید تا تاریخچه را بفرستد؛ سرور نسخه‌ای برای فرستادن ندارد.';
}
