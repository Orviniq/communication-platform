/// A user-initiated diagnostics report, and the only shape one may have.
///
/// The redaction rule this file exists to enforce is structural, not editorial.
/// A report is a list of [DiagnosticEntry] values; an entry's key is a
/// [DiagnosticField], which is an enumeration, and an entry's value is a
/// [DiagnosticValue], whose every subclass is constructible **only** from a
/// boolean, an enumeration, a bounded integer, or a compile-time constant this
/// repository declares. There is no constructor that takes a runtime string, so
/// there is no path by which a username, a display name, a message body, a
/// device label, a token, a server origin, a capability or a key can reach the
/// export — not because a reviewer checked, but because the type will not hold
/// one.
///
/// The rendered text is deliberately locale-independent ASCII. It is a
/// technical artifact whose recipient may not read the sender's language, and
/// showing a translated summary on screen while copying something else would
/// break the one guarantee that makes this surface safe to offer: what the user
/// reads is byte-for-byte what the user copies.
library;

/// Where an entry appears, and in what order.
enum DiagnosticSection {
  application,
  device,
  storage,
  delivery,
  network;

  /// The stable ASCII heading used in the export.
  String get token => switch (this) {
    DiagnosticSection.application => 'application',
    DiagnosticSection.device => 'device',
    DiagnosticSection.storage => 'storage',
    DiagnosticSection.delivery => 'delivery',
    DiagnosticSection.network => 'network',
  };
}

/// Every question a report may answer.
///
/// Closed by construction: a source that wants to say something new has to add
/// a value here, in this file, where the decision is visible — which is what
/// stops a diagnostics collector from growing a free-form "notes" field.
enum DiagnosticField {
  reportFormat(DiagnosticSection.application, 'report_format'),
  applicationVersion(DiagnosticSection.application, 'version'),
  buildFlavor(DiagnosticSection.application, 'flavor'),
  disclosureRevision(DiagnosticSection.application, 'disclosure_revision'),
  disclosureAccepted(DiagnosticSection.application, 'disclosure_accepted'),
  languagePreference(DiagnosticSection.application, 'language_preference'),
  themePreference(DiagnosticSection.application, 'theme_preference'),
  generatedAtUtcHour(DiagnosticSection.application, 'generated_utc_hour'),

  platform(DiagnosticSection.device, 'platform'),
  cryptoCore(DiagnosticSection.device, 'crypto_core'),

  databaseSchema(DiagnosticSection.storage, 'database_schema'),
  protectedStorage(DiagnosticSection.storage, 'protected_storage'),
  conversationCount(DiagnosticSection.storage, 'conversations'),
  pendingOutbound(DiagnosticSection.storage, 'pending_outbound'),
  pendingInbound(DiagnosticSection.storage, 'pending_inbound'),
  quarantinedInput(DiagnosticSection.storage, 'quarantined_input'),

  sessionState(DiagnosticSection.delivery, 'session'),
  notificationAuthorization(DiagnosticSection.delivery, 'notifications'),
  sustainedDelivery(DiagnosticSection.delivery, 'sustained_delivery'),
  deliverySession(DiagnosticSection.delivery, 'delivery_session'),
  queueGapDetected(DiagnosticSection.delivery, 'queue_gap_detected'),

  networkSucceeded(DiagnosticSection.network, 'succeeded'),
  networkBackendRejected(DiagnosticSection.network, 'backend_rejected'),
  networkTransportFailed(DiagnosticSection.network, 'transport_failed'),
  networkCancelled(DiagnosticSection.network, 'cancelled'),
  networkMalformedResponse(DiagnosticSection.network, 'malformed_response'),
  networkSizeRejected(DiagnosticSection.network, 'size_rejected'),
  networkSlowestBucket(DiagnosticSection.network, 'slowest_response'),
  networkWorstOperation(DiagnosticSection.network, 'most_failed_operation');

  const DiagnosticField(this.section, this.token);

  final DiagnosticSection section;

  /// The stable ASCII key used in the export. Never translated.
  final String token;
}

/// How many of something, to an order of magnitude and no closer.
///
/// Exact counts are not prohibited values, but they are a needlessly precise
/// description of one person's usage to put in a document they may hand to
/// somebody else. A bucket answers every question a reader of this report
/// actually has — is the outbox empty, is it backed up, is it enormous —
/// without describing how much they talk.
enum DiagnosticQuantity {
  none('0'),
  upToNine('1-9'),
  upToNinetyNine('10-99'),
  upToNineHundredNinetyNine('100-999'),
  thousandOrMore('1000+');

  const DiagnosticQuantity(this.token);

  final String token;

  static DiagnosticQuantity of(int count) => switch (count) {
    <= 0 => DiagnosticQuantity.none,
    < 10 => DiagnosticQuantity.upToNine,
    < 100 => DiagnosticQuantity.upToNinetyNine,
    < 1000 => DiagnosticQuantity.upToNineHundredNinetyNine,
    _ => DiagnosticQuantity.thousandOrMore,
  };
}

/// A value a report may carry.
///
/// Sealed, and every constructor takes something that cannot be
/// adversary-controlled. See the library comment for why that is the whole
/// mechanism.
sealed class DiagnosticValue {
  const DiagnosticValue();

  /// A yes/no answer.
  const factory DiagnosticValue.flag(bool value) = DiagnosticFlag;

  /// A value drawn from one of this application's own enumerations. The stored
  /// text is [Enum.name], which is a compile-time constant of this source tree.
  /// [DiagnosticWord] is one such enumeration, for states that have none of
  /// their own.
  const factory DiagnosticValue.term(Enum value) = DiagnosticTerm;

  /// An order-of-magnitude count.
  const factory DiagnosticValue.quantity(DiagnosticQuantity value) =
      DiagnosticQuantityValue;

  /// A small integer this application produced — a schema version, a disclosure
  /// revision. Clamped so that a corrupted source cannot widen the export.
  const factory DiagnosticValue.number(int value) = DiagnosticNumber;

  /// A compile-time constant declared in this repository, such as the packaged
  /// application version. Rejected unless it is a short, safe token, so that a
  /// future caller cannot quietly route runtime text through it.
  factory DiagnosticValue.constant(String value) = DiagnosticConstant.of;

  String get token;
}

/// States that belong to the report itself rather than to any one subsystem.
enum DiagnosticWord {
  unknown,
  unavailable,
  available,
  withheld,
  yes,
  no,
  none;

  String get token => name;
}

final class DiagnosticFlag extends DiagnosticValue {
  const DiagnosticFlag(this.value);

  final bool value;

  @override
  String get token =>
      value ? DiagnosticWord.yes.token : DiagnosticWord.no.token;
}

final class DiagnosticTerm extends DiagnosticValue {
  const DiagnosticTerm(this.value);

  final Enum value;

  @override
  String get token => value is DiagnosticWord
      ? (value as DiagnosticWord).token
      : _asToken(value.name);
}

final class DiagnosticQuantityValue extends DiagnosticValue {
  const DiagnosticQuantityValue(this.value);

  final DiagnosticQuantity value;

  @override
  String get token => value.token;
}

final class DiagnosticNumber extends DiagnosticValue {
  const DiagnosticNumber(this.value);

  final int value;

  @override
  String get token => value < 0 || value > 999999
      ? DiagnosticWord.unknown.token
      : value.toString();
}

final class DiagnosticConstant extends DiagnosticValue {
  const DiagnosticConstant._(this.value);

  /// Accepts only a short token of characters a version or build name uses.
  /// Anything else becomes `unknown`, which fails closed rather than exporting
  /// text nobody declared.
  factory DiagnosticConstant.of(String value) =>
      DiagnosticConstant._(_safeConstant.hasMatch(value) ? value : null);

  static final _safeConstant = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');

  final String? value;

  @override
  String get token => value ?? DiagnosticWord.unknown.token;
}

/// One line of a report.
final class DiagnosticEntry {
  const DiagnosticEntry(this.field, this.value);

  final DiagnosticField field;
  final DiagnosticValue value;

  String get line => '${field.token}=${value.token}';
}

/// The complete report, ordered and deduplicated.
final class DiagnosticsReport {
  DiagnosticsReport(Iterable<DiagnosticEntry> entries)
    : entries = List.unmodifiable(_ordered(entries));

  /// The version of the export's own layout. It moves when a field is added,
  /// removed or redefined, so somebody reading an old paste knows what they
  /// have.
  static const formatVersion = 2;

  final List<DiagnosticEntry> entries;

  static List<DiagnosticEntry> _ordered(Iterable<DiagnosticEntry> entries) {
    final byField = <DiagnosticField, DiagnosticEntry>{};
    for (final entry in entries) {
      byField[entry.field] = entry;
    }
    final ordered = <DiagnosticEntry>[];
    for (final field in DiagnosticField.values) {
      final entry = byField[field];
      if (entry != null) {
        ordered.add(entry);
      }
    }
    return ordered;
  }

  /// Exactly what a user reads on the screen and exactly what they copy.
  String render() {
    final buffer = StringBuffer();
    DiagnosticSection? section;
    for (final entry in entries) {
      if (entry.field.section != section) {
        if (section != null) {
          buffer.writeln();
        }
        section = entry.field.section;
        buffer.writeln('[${section.token}]');
      }
      buffer.writeln(entry.line);
    }
    return buffer.toString();
  }
}

/// Reduces an enumeration name to the export's character set.
///
/// Dart identifiers are already within it, so this changes nothing in practice
/// and exists so that the rendered text has one grammar a test can assert
/// rather than "whatever the enumerations happen to be called".
String _asToken(String name) {
  final buffer = StringBuffer();
  for (final unit in name.codeUnits.take(64)) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isUpper = unit >= 0x41 && unit <= 0x5a;
    final isLower = unit >= 0x61 && unit <= 0x7a;
    buffer.writeCharCode(isDigit || isUpper || isLower ? unit : 0x5f);
  }
  final token = buffer.toString();
  return token.isEmpty ? DiagnosticWord.unknown.token : token;
}
