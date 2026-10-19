import 'dart:async';

/// What a chat screen reports for typing (ADR-098 D3), and nothing more: no
/// text, only whether the composer holds any.
sealed class ChatActivity {
  const ChatActivity(this.conversationId);

  final String conversationId;
}

/// The composer's text changed.
final class ChatTextEdited extends ChatActivity {
  const ChatTextEdited(super.conversationId, {required this.hasText});

  /// Whether the composer holds anything after the change.
  final bool hasText;
}

/// The composer's text was sent.
final class ChatTextSent extends ChatActivity {
  const ChatTextSent(super.conversationId);
}

/// A message from another device appeared in the conversation on screen,
/// which ends that device's typing there.
final class ChatMessageArrived extends ChatActivity {
  const ChatMessageArrived(
    super.conversationId, {
    required this.senderDeviceId,
  });

  final String senderDeviceId;
}

/// Carries chat screens' activity to the presence channel.
///
/// One for the process, so that a screen reports whether or not a channel is
/// running yet, and a channel hears whichever screen is open.
final class ChatActivityHub {
  final _events = StreamController<ChatActivity>.broadcast();

  Stream<ChatActivity> get events => _events.stream;

  void report(ChatActivity activity) {
    if (!_events.isClosed) {
      _events.add(activity);
    }
  }

  Future<void> dispose() => _events.close();
}
