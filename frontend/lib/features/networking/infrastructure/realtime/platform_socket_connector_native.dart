import 'dart:io';

import 'package:communication_platform/features/networking/infrastructure/realtime/socket_connector.dart';
import 'package:web_socket_channel/io.dart';

final class PlatformSocketConnector implements SocketConnector {
  /// [createHttpClient] supplies the client carrying the provisioned trust, so
  /// the socket verifies the peer against the same authority as the REST
  /// client. Null leaves the socket on platform default trust, which is correct
  /// only where no private authority is provisioned.
  const PlatformSocketConnector({HttpClient Function()? createHttpClient})
    : this._(createHttpClient);

  const PlatformSocketConnector._(this._createHttpClient);

  final HttpClient Function()? _createHttpClient;

  @override
  Future<SocketConnection> connect({
    required Uri uri,
    required String accessToken,
    required Duration timeout,
    Duration? keepAlive,
  }) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
      connectTimeout: timeout,
      // `dart:io` sends a ping every interval and, when one is not answered
      // within the same interval, closes the connection as `goingAway`. That
      // close is what turns a socket that has silently died into a
      // reconnect this application can act on.
      pingInterval: keepAlive,
      customClient: _createHttpClient?.call(),
    );
    await channel.ready;
    return _ChannelSocketConnection(channel);
  }
}

final class _ChannelSocketConnection implements SocketConnection {
  const _ChannelSocketConnection(this.channel);

  final IOWebSocketChannel channel;

  @override
  int? get closeCode => channel.closeCode;

  @override
  Stream<Object?> get messages => channel.stream;

  @override
  void add(Object message) => channel.sink.add(message);

  @override
  Future<void> close([int? code]) => channel.sink.close(code);
}
