import 'package:communication_platform/app/design_system/app_components.dart';
import 'package:communication_platform/app/design_system/app_icons.dart';
import 'package:communication_platform/app/design_system/app_tokens.dart';
import 'package:communication_platform/features/contacts/presentation/contact_avatar.dart';
import 'package:communication_platform/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// One member who read a message, as the reader list draws them (ADR-091 D7).
final class ChatMessageReader {
  const ChatMessageReader({
    required this.userId,
    required this.name,
    required this.avatarSeed,
    required this.readAt,
  });

  /// Keys the entry. The list never draws it.
  final String userId;

  /// The member's display name, or a short id for one the group does not name.
  final String name;

  /// The colour seed of the member's avatar, the one Group Info gives them.
  final int avatarSeed;

  /// When the member read the message, in local time, or null when no read
  /// time could be placed (ADR-091 D8).
  final DateTime? readAt;
}

/// What a message sheet reads beside its message: who has read it.
///
/// Read-only, like [ChatAttachmentTransfers]: the screen that owns the
/// conversation gives an implementation, and the bubble never reaches storage.
abstract interface class ChatMessageReaders {
  /// The readers of [messageId], newest read first, each time they change.
  Stream<List<ChatMessageReader>> watch(String messageId);
}

/// The readers of one conversation's messages.
///
/// Provided above the timeline of a group chat, the only conversation whose
/// sender sees a reader list (ADR-091 D7). A timeline without one gives the
/// sheet of an own message no reader row, as a direct chat's does.
final class ChatReadersScope extends InheritedWidget {
  const ChatReadersScope({
    required this.readers,
    required super.child,
    super.key,
  });

  final ChatMessageReaders readers;

  /// Read at the moment a sheet opens, not while a widget builds: a sheet is a
  /// new route and cannot see this scope from its own context, so the bubble
  /// reads it first and hands the object on. No dependency is registered,
  /// because nothing about a bubble depends on it.
  static ChatMessageReaders? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatReadersScope>()?.readers;

  @override
  bool updateShouldNotify(ChatReadersScope oldWidget) =>
      !identical(readers, oldWidget.readers);
}

/// How a read time is written: the time of day as the timeline writes a
/// message time, with the date before it when the read was not [now]'s day.
///
/// "Time unknown" when no time could be placed.
String chatReadTimeLabel(
  BuildContext context,
  DateTime? readAt, {
  required DateTime now,
}) {
  final strings = AppLocalizations.of(context);
  if (readAt == null) return strings.chatReadTimeUnknown;
  final material = MaterialLocalizations.of(context);
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(readAt));
  final sameDay =
      readAt.year == now.year &&
      readAt.month == now.month &&
      readAt.day == now.day;
  return sameDay
      ? time
      : strings.chatReadDateAndTime(material.formatMediumDate(readAt), time);
}

/// Follows the readers of one message and hands each answer to [builder].
///
/// The stream is opened once for the life of this widget, so a rebuild of the
/// sheet around it (a keyboard, a text scale) does not open a new query.
class _ReadersBuilder extends StatefulWidget {
  const _ReadersBuilder({
    required this.readers,
    required this.messageId,
    required this.builder,
  });

  final ChatMessageReaders readers;
  final String messageId;
  final AsyncWidgetBuilder<List<ChatMessageReader>> builder;

  @override
  State<_ReadersBuilder> createState() => _ReadersBuilderState();
}

class _ReadersBuilderState extends State<_ReadersBuilder> {
  late Stream<List<ChatMessageReader>> _stream = _open();

  Stream<List<ChatMessageReader>> _open() =>
      widget.readers.watch(widget.messageId);

  @override
  void didUpdateWidget(_ReadersBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.readers, widget.readers) ||
        oldWidget.messageId != widget.messageId) {
      _stream = _open();
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<ChatMessageReader>>(
    stream: _stream,
    builder: widget.builder,
  );
}

/// The row at the top of the sheet of an own group message: "Seen by N" or
/// "Not seen yet", live, and a button that opens the list (ADR-091 D7).
///
/// It holds its height until the first answer, so the sheet does not grow a
/// row a moment after it opens. An error leaves no row at all, because a count
/// that cannot be read is not "Not seen yet".
class ChatReadersRow extends StatelessWidget {
  const ChatReadersRow({
    required this.readers,
    required this.messageId,
    required this.onOpen,
    super.key,
  });

  final ChatMessageReaders readers;
  final String messageId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => _ReadersBuilder(
    readers: readers,
    messageId: messageId,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const SizedBox.shrink();
      final list = snapshot.data;
      if (list == null) {
        return const SizedBox(height: AppFocus.minimumTarget);
      }
      final strings = AppLocalizations.of(context);
      final label = list.isEmpty
          ? strings.chatNotSeenYet
          : strings.chatSeenByCount(list.length);
      final colors = context.tokens.colors;
      return Semantics(
        button: true,
        label: label,
        hint: strings.chatReadersOpenHint,
        onTap: onOpen,
        excludeSemantics: true,
        child: ListTile(
          key: const ValueKey('chat-readers-row'),
          minTileHeight: AppFocus.minimumTarget,
          leading: AppIcon(AppIcons.read, color: colors.accent),
          title: Text(
            label,
            style: context.tokens.typography.body.copyWith(
              color: colors.textPrimary,
            ),
          ),
          onTap: onOpen,
        ),
      );
    },
  );
}

/// Opens the list of the members who read [messageId], newest read first.
///
/// [readers] is handed in and not read from the scope: the sheet is a new
/// route. The list follows the stream while it is open.
Future<void> showChatReaderList({
  required BuildContext context,
  required ChatMessageReaders readers,
  required String messageId,
}) {
  final strings = AppLocalizations.of(context);
  return showAppSheet<void>(
    context: context,
    semanticLabel: strings.chatReadersTitle,
    childScrolls: true,
    child: _ChatReaderList(readers: readers, messageId: messageId),
  );
}

class _ChatReaderList extends StatelessWidget {
  const _ChatReaderList({required this.readers, required this.messageId});

  final ChatMessageReaders readers;
  final String messageId;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = context.tokens.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            strings.chatReadersTitle,
            style: context.tokens.typography.section,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        Flexible(
          child: _ReadersBuilder(
            readers: readers,
            messageId: messageId,
            builder: (context, snapshot) {
              final list = snapshot.data;
              if (list == null) return const SizedBox.shrink();
              if (list.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.x4),
                  child: Text(
                    strings.chatNotSeenYet,
                    textAlign: TextAlign.center,
                    style: context.tokens.typography.body.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                );
              }
              final now = DateTime.now();
              return ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (context, index) => _ChatReaderEntry(
                  key: ValueKey('chat-reader-${list[index].userId}'),
                  reader: list[index],
                  now: now,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One member and the time they read: a single node for a screen reader, which
/// reads the name and the time and nothing of the avatar.
class _ChatReaderEntry extends StatelessWidget {
  const _ChatReaderEntry({required this.reader, required this.now, super.key});

  final ChatMessageReader reader;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = context.tokens.colors;
    final time = chatReadTimeLabel(context, reader.readAt, now: now);
    return Semantics(
      container: true,
      label: AppLocalizations.of(
        context,
      ).chatReaderSemantics(reader.name, time),
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppFocus.minimumTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          child: Row(
            children: [
              ContactAvatar(
                username: reader.name,
                semanticLabel: reader.name,
                authenticatedSeed: reader.avatarSeed,
                radius: 20,
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reader.name,
                      style: context.tokens.typography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      time,
                      style: context.tokens.typography.label.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
