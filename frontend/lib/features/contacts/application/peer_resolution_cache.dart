import 'package:communication_platform/core/application/ports/time_source.dart';
import 'package:communication_platform/core/protocol/identity_protocol_model.dart';
import 'package:communication_platform/core/result/result.dart';
import 'package:communication_platform/features/contacts/application/ports/contact_ports.dart';
import 'package:communication_platform/features/contacts/domain/contact_model.dart';

/// How long one server answer about a peer may stand in for a fresh one.
///
/// Thirty seconds is the span of one delivery cycle, which is the only thing
/// this cache is for. Every redundant resolution the phase is about is inside
/// one: a preparation's peer lookup, its own-account lookup and the
/// re-resolution a prekey claim performs are consecutive, and the device-log
/// gossip the same cycle owes that peer is separated from them by one outbox
/// flush and one inbox pass. Ten seconds covers the first three and loses the
/// fourth on any device with a mailbox; a minute would start joining
/// *different* cycles, which nothing asked for and nothing invalidates.
///
/// What it costs is bounded and stated. A peer device revoked or added with no
/// local signal whatsoever — no `stale_devices` response, no envelope from the
/// new device, no trust transition, no user action — is invisible for at most
/// thirty seconds longer than it already was. That is small beside the window
/// that already exists between sealing a ciphertext and delivering it, which
/// the outbox's own backoff measures in minutes, and it is far below the
/// fifteen-minute floor at which the platform can wake this process at all, so
/// no entry can survive from one background catch-up to the next.
const Duration defaultPeerResolutionTtl = Duration(seconds: 30);

/// How many users may be remembered before expired entries are swept.
///
/// The maps are bounded by the number of distinct people this process resolved
/// inside one window, which is small. This exists so that a long-lived process
/// talking to many contacts cannot accumulate dead entries indefinitely.
const int _sweepThreshold = 64;

/// Remembers a peer's server answers for [ttl], and coalesces concurrent asks
/// for the same one into a single round trip.
///
/// **It caches responses, not conclusions.** It decorates
/// [PeerIdentityRemotePort], which is the seam between
/// `ClientAuthenticationService` and the network, so a served answer re-enters
/// the same authentication the network's would have: the master-key
/// comparison, the unsigned-device rejection, the device transition check, the
/// hash-chain and sequence verification, the current-live-set requirement on
/// the head record and the trust-state gates all run again, on every call, on
/// every path. A cache hit cannot satisfy a caller the live path would have
/// refused, because the caller is the same code reaching the same verdict from
/// the same bytes. It cannot widen a device set either: the widest set it can
/// produce is one the server itself returned inside [ttl].
///
/// **A prekey claim is not part of it.** `claimPrekeyBundles` consumes
/// one-time prekeys and is `ReplaySafety.never`; it is delegated with no map,
/// no in-flight entry and no memo, so there is nothing here that could serve
/// one twice.
///
/// **Nothing failed is remembered.** A failure is precisely the answer that
/// deserves another attempt, and remembering one would let a dropped
/// connection keep writing `identityUnavailable` against a contact for the
/// length of the window.
///
/// **The batched read passes through.** `fetchPeerStates` is never
/// remembered or joined, and it is the one request that empties entries
/// rather than fills them: a peer it finds moved is forgotten here, because
/// its answer becomes that peer's stored state and nothing older may be
/// served against it.
final class PeerIdentityRoundTripCache
    implements PeerIdentityRemotePort, PeerResolutionCachePort {
  PeerIdentityRoundTripCache({
    required this.remote,
    required this.clock,
    this.ttl = defaultPeerResolutionTtl,
  });

  final PeerIdentityRemotePort remote;
  final TimeSource clock;
  final Duration ttl;

  final Map<String, _RememberedIdentity> _identities = {};
  final Map<String, _RememberedDevices> _devices = {};

  /// Requests this process has already made and not yet heard back about.
  ///
  /// Joining one is the strongest form of freshness there is — the joiner
  /// receives the answer to a request that is still open — so these are keyed
  /// on everything that changes the answer and on nothing else.
  final Map<String, Future<Result<PeerIdentityPublic>>> _identityFlights = {};
  final Map<(String, String?), Future<Result<PeerDeviceRefresh>>>
  _deviceFlights = {};
  final Map<(String, int?), Future<Result<PeerDeviceLogPage>>> _logFlights = {};

  /// Users a [live] resolution is running for, counted rather than flagged so
  /// that nested and concurrent resolutions cannot end each other's bypass.
  final Map<String, int> _bypassed = {};

  /// For each user, when a batched read last landed that moved them.
  ///
  /// An answer asked before then may be older than what that read stored, so
  /// it is not remembered: served later, a head below the stored one would be
  /// read as a fork.
  final Map<String, DateTime> _floors = {};

  @override
  Future<Result<PeerIdentityPublic>> fetchIdentity({
    required String userId,
  }) async {
    // The one request in this port with no conditional form. The endpoint
    // offers no ETag and may not be given one, so the only way to stop asking
    // for an identity four times inside one delivery cycle is to remember the
    // answer to the first ask.
    if (!_isBypassed(userId)) {
      final remembered = _identities[userId];
      if (remembered != null && _isFresh(remembered.at)) {
        return Result.success(remembered.identity);
      }
      final inFlight = _identityFlights[userId];
      if (inFlight != null) {
        return inFlight;
      }
    }
    final asked = clock.now();
    final flight = remote.fetchIdentity(userId: userId);
    _identityFlights[userId] = flight;
    try {
      final result = await flight;
      if (result case Success(value: final identity)) {
        final held = _identities[userId];
        if ((held == null || !held.at.isAfter(asked)) &&
            !_predatesFloor(userId, asked)) {
          _identities[userId] = _RememberedIdentity(asked, identity);
          _sweepIdentities();
        }
      }
      return result;
    } finally {
      if (identical(_identityFlights[userId], flight)) {
        _identityFlights.removeWhere((key, _) => key == userId);
      }
    }
  }

  @override
  Future<Result<PeerDeviceRefresh>> fetchDevices({
    required String userId,
    String? etag,
  }) async {
    if (!_isBypassed(userId)) {
      final remembered = _devices[userId];
      if (remembered != null &&
          _isFresh(remembered.at) &&
          remembered.answers(etag)) {
        return Result.success(remembered.response);
      }
      final inFlight = _deviceFlights[(userId, etag)];
      if (inFlight != null) {
        return inFlight;
      }
    }
    final asked = clock.now();
    final flight = remote.fetchDevices(userId: userId, etag: etag);
    _deviceFlights[(userId, etag)] = flight;
    try {
      final result = await flight;
      if (result case Success(value: final response)) {
        final held = _devices[userId];
        if ((held == null || !held.at.isAfter(asked)) &&
            !_predatesFloor(userId, asked)) {
          _devices[userId] = _RememberedDevices(asked, etag, response);
          _sweepDevices();
        }
      }
      return result;
    } finally {
      if (identical(_deviceFlights[(userId, etag)], flight)) {
        _deviceFlights.removeWhere((key, _) => key == (userId, etag));
      }
    }
  }

  @override
  Future<Result<List<ClaimedPrekeyBundle>>> claimPrekeyBundles({
    required String userId,
    required List<String> deviceIds,
  }) {
    // Deliberately, structurally, unremembered. This request consumes one-time
    // prekeys on the server; serving one twice is a cryptographic fault and not
    // a saved round trip, so it does not reach a map, an in-flight entry or a
    // bypass check on its way through.
    return remote.claimPrekeyBundles(userId: userId, deviceIds: deviceIds);
  }

  @override
  Future<Result<PeerDeviceLogPage>> fetchDeviceLog({
    required String userId,
    int? after,
  }) async {
    // Coalesced but never stored, and the asymmetry is the point. A stored page
    // outlives the device answer that said which head to expect, and a page
    // whose head no longer matches is read as a *fork* — a false alarm that
    // blocks every send to every peer. Sharing an open request carries no such
    // risk: both callers receive the answer to one request made at one instant.
    //
    // It also costs almost nothing to give up. The first resolution of a cycle
    // advances the stored head, and every later one in that cycle then finds
    // `advertisedHead` equal to it and asks for no page at all.
    if (!_isBypassed(userId)) {
      final inFlight = _logFlights[(userId, after)];
      if (inFlight != null) {
        return inFlight;
      }
    }
    final flight = remote.fetchDeviceLog(userId: userId, after: after);
    _logFlights[(userId, after)] = flight;
    try {
      return await flight;
    } finally {
      if (identical(_logFlights[(userId, after)], flight)) {
        _logFlights.removeWhere((key, _) => key == (userId, after));
      }
    }
  }

  @override
  Future<Result<Map<String, PeerStateRead>>> fetchPeerStates(
    List<PeerStateQuery> peers,
  ) async {
    // Not remembered and not joined. One call answers for everybody a fan-out
    // names, and the fan-out makes it once; what is worth keeping from it is
    // already kept, as a tag, in each peer's stored record.
    //
    // What it changes here is everything else this cache holds about those
    // peers. An answer that is not `unchanged` is about to become the stored
    // state of that peer, newer than any identity or device answer remembered
    // here and newer than any still in flight. Serving one of those afterwards
    // would hand `_refresh` a head below the one it has just stored, and that
    // is read as a fork, which withholds every send to everybody. So a peer
    // that moved is forgotten, and nothing asked before this answer landed is
    // remembered for it. A peer whose tag still held has stored nothing new,
    // and what is remembered about it stays as good as it was.
    final result = await remote.fetchPeerStates(peers);
    if (result case Success(value: final reads)) {
      final landed = clock.now();
      for (final MapEntry(key: userId, value: read) in reads.entries) {
        if (read is! PeerStateUnchanged) {
          invalidate(userId);
          _floors[userId] = landed;
        }
      }
      _sweepFloors();
    }
    return result;
  }

  @override
  void invalidate(String userId) {
    _identities.remove(userId);
    _devices.remove(userId);
    _identityFlights.removeWhere((key, _) => key == userId);
    _deviceFlights.removeWhere((key, _) => key.$1 == userId);
    _logFlights.removeWhere((key, _) => key.$1 == userId);
  }

  @override
  void invalidateAll() {
    _identities.clear();
    _devices.clear();
    _identityFlights.clear();
    _deviceFlights.clear();
    _logFlights.clear();
  }

  @override
  Future<T> live<T>(String userId, Future<T> Function() resolve) async {
    invalidate(userId);
    _bypassed.update(userId, (depth) => depth + 1, ifAbsent: () => 1);
    try {
      return await resolve();
    } finally {
      final remaining = (_bypassed[userId] ?? 1) - 1;
      if (remaining <= 0) {
        _bypassed.remove(userId);
      } else {
        _bypassed[userId] = remaining;
      }
    }
  }

  bool _isBypassed(String userId) => _bypassed.containsKey(userId);

  bool _predatesFloor(String userId, DateTime asked) {
    final floor = _floors[userId];
    return floor != null && asked.isBefore(floor);
  }

  /// Measured from when the request was *made* rather than when it returned, so
  /// [ttl] is a true upper bound on how old a served answer can be.
  bool _isFresh(DateTime asked) => clock.now().difference(asked) < ttl;

  void _sweepIdentities() {
    if (_identities.length > _sweepThreshold) {
      _identities.removeWhere((_, held) => !_isFresh(held.at));
    }
  }

  void _sweepDevices() {
    if (_devices.length > _sweepThreshold) {
      _devices.removeWhere((_, held) => !_isFresh(held.at));
    }
  }

  /// A floor older than [ttl] protects nothing: an answer asked before it is
  /// too old to be served anyway.
  void _sweepFloors() {
    if (_floors.length > _sweepThreshold) {
      _floors.removeWhere((_, landed) => !_isFresh(landed));
    }
  }
}

final class _RememberedIdentity {
  const _RememberedIdentity(this.at, this.identity);

  final DateTime at;
  final PeerIdentityPublic identity;
}

final class _RememberedDevices {
  const _RememberedDevices(this.at, this.sentEtag, this.response);

  final DateTime at;

  /// The ETag that was sent to obtain [response], which is the only thing that
  /// makes a `304` mean anything.
  final String? sentEtag;

  final PeerDeviceRefresh response;

  /// Whether this answer is the one the server would give for [etag].
  ///
  /// A `200` is a complete answer and stands for any request: it carries the
  /// devices, the ETag and the head, which is strictly more than a `304` tells
  /// a caller. A `304` is a statement *about* the ETag that produced it, and
  /// means nothing to a caller holding a different one.
  bool answers(String? etag) =>
      response is PeerDevicesUpdated || sentEtag == etag;
}
