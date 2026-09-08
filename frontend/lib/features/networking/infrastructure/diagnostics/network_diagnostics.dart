enum NetworkOperation {
  health,
  authRegister,
  authLogin,
  authRenew,
  authLogout,
  api,
  websocket,
  syncDrain,
  syncAcknowledge,
  syncSend,
}

enum NetworkOutcome {
  succeeded,
  backendRejected,
  transportFailed,
  cancelled,
  malformedResponse,
  sizeRejected,
}

enum DurationBucket { under100Ms, under500Ms, under2Seconds, over2Seconds }

/// Deliberately cannot contain payloads, headers, URLs, tokens, or identifiers.
final class NetworkDiagnosticEvent {
  const NetworkDiagnosticEvent({
    required this.operation,
    required this.outcome,
    required this.duration,
    required this.attempt,
    this.statusCode,
  });

  final NetworkOperation operation;
  final NetworkOutcome outcome;
  final DurationBucket duration;
  final int attempt;
  final int? statusCode;
}

abstract interface class NetworkDiagnostics {
  void record(NetworkDiagnosticEvent event);
}

final class NoopNetworkDiagnostics implements NetworkDiagnostics {
  const NoopNetworkDiagnostics();

  @override
  void record(NetworkDiagnosticEvent event) {}
}

/// What the counters held while this process has been alive.
final class NetworkDiagnosticsSnapshot {
  const NetworkDiagnosticsSnapshot({
    required this.outcomeCounts,
    required this.slowestObserved,
    required this.mostFailedOperation,
  });

  static const empty = NetworkDiagnosticsSnapshot(
    outcomeCounts: <NetworkOutcome, int>{},
    slowestObserved: null,
    mostFailedOperation: null,
  );

  final Map<NetworkOutcome, int> outcomeCounts;

  /// The highest duration bucket any request reached, or null if none has.
  final DurationBucket? slowestObserved;

  /// The operation with the most non-success outcomes, or null when every
  /// request so far succeeded.
  final NetworkOperation? mostFailedOperation;

  int countOf(NetworkOutcome outcome) => outcomeCounts[outcome] ?? 0;
}

/// Counts request outcomes in memory, and nothing else.
///
/// The state is one integer per enumeration cell, so it is O(1) whatever the
/// application does, and it holds no event, no order and no timing beyond the
/// coarsest bucket the event already carried. It is deliberately **not**
/// durable: a diagnostics buffer that survived a restart would be a record of
/// when its owner used the application, kept for a screen almost nobody opens.
/// A new process starts from zero, and the report says which process it is
/// describing by saying nothing about any other.
final class RecordingNetworkDiagnostics implements NetworkDiagnostics {
  RecordingNetworkDiagnostics();

  /// Past this, a counter stops moving. Nothing reads the exact value — the
  /// export buckets it — and a bound is what keeps a retry storm from turning
  /// a counter into an unbounded number.
  static const counterCeiling = 1000000;

  final Map<NetworkOutcome, int> _outcomes = <NetworkOutcome, int>{};
  final Map<NetworkOperation, int> _failuresByOperation =
      <NetworkOperation, int>{};
  DurationBucket? _slowest;

  @override
  void record(NetworkDiagnosticEvent event) {
    _outcomes[event.outcome] = _bump(_outcomes[event.outcome]);
    if (event.outcome != NetworkOutcome.succeeded) {
      _failuresByOperation[event.operation] = _bump(
        _failuresByOperation[event.operation],
      );
    }
    final slowest = _slowest;
    if (slowest == null || event.duration.index > slowest.index) {
      _slowest = event.duration;
    }
  }

  NetworkDiagnosticsSnapshot snapshot() {
    NetworkOperation? worst;
    var worstCount = 0;
    // Iterated in declaration order rather than insertion order so that a tie
    // resolves the same way every time and two reports from the same state are
    // byte-identical.
    for (final operation in NetworkOperation.values) {
      final count = _failuresByOperation[operation] ?? 0;
      if (count > worstCount) {
        worst = operation;
        worstCount = count;
      }
    }
    return NetworkDiagnosticsSnapshot(
      outcomeCounts: Map.unmodifiable(_outcomes),
      slowestObserved: _slowest,
      mostFailedOperation: worst,
    );
  }

  static int _bump(int? current) {
    final next = (current ?? 0) + 1;
    return next > counterCeiling ? counterCeiling : next;
  }
}

/// Safe text intended for a later, user-initiated diagnostics exporter.
String formatRedactedDiagnostic(NetworkDiagnosticEvent event) =>
    'network operation=${event.operation.name} '
    'outcome=${event.outcome.name} duration=${event.duration.name} '
    'attempt=${event.attempt} status=${event.statusCode ?? "none"}';

DurationBucket bucketDuration(Duration duration) =>
    switch (duration.inMilliseconds) {
      < 100 => DurationBucket.under100Ms,
      < 500 => DurationBucket.under500Ms,
      < 2000 => DurationBucket.under2Seconds,
      _ => DurationBucket.over2Seconds,
    };
