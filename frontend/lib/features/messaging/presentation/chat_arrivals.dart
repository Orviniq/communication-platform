import 'package:communication_platform/features/messaging/domain/conversation_model.dart';

/// Follows the messages a chat screen has loaded, and names the sender device
/// of each message from another account that appears at the newest end, so
/// that its typing line ends with it (ADR-098 D3).
///
/// The first page is what was already there, and names nobody. An older page
/// loaded above the window changes nothing at the newest end, and names
/// nobody either.
final class ChatArrivals {
  ChatArrivals({required this.currentUserId, required this.report});

  final String currentUserId;
  final void Function(String senderDeviceId) report;

  var _started = false;
  String? _newest;

  /// [messages] oldest first, as a page holds them.
  void follow(List<ConversationMessage> messages) {
    final newest = messages.isEmpty ? null : messages.last.messageId;
    if (!_started) {
      _started = true;
      _newest = newest;
      return;
    }
    if (newest == null || newest == _newest) {
      return;
    }
    final own = currentUserId.toLowerCase();
    final senders = <String>{};
    for (var index = messages.length - 1; index >= 0; index -= 1) {
      final message = messages[index];
      if (message.messageId == _newest) {
        break;
      }
      if (message.senderUserId.toLowerCase() != own) {
        senders.add(message.senderDeviceId.toLowerCase());
      }
    }
    _newest = newest;
    senders.forEach(report);
  }
}
