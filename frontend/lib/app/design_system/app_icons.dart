import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

/// Typed semantic icon token. Package icon names never escape this layer.
@immutable
class AppIconData {
  const AppIconData._(this.icon, this.debugName, {this.mirrorsInRtl = false});

  final IconData icon;
  final String debugName;
  final bool mirrorsInRtl;
}

/// The only application mapping from semantics to Forui's bundled Lucide set.
abstract final class AppIcons {
  static const chats = AppIconData._(FLucideIcons.messagesSquare, 'chats');
  static const voiceRooms = AppIconData._(FLucideIcons.radio, 'voiceRooms');
  static const settings = AppIconData._(FLucideIcons.settings, 'settings');
  static const search = AppIconData._(FLucideIcons.search, 'search');
  static const add = AppIconData._(FLucideIcons.plus, 'add');
  static const back = AppIconData._(
    FLucideIcons.arrowLeft,
    'back',
    mirrorsInRtl: true,
  );
  static const forward = AppIconData._(
    FLucideIcons.arrowRight,
    'forward',
    mirrorsInRtl: true,
  );
  static const success = AppIconData._(FLucideIcons.circleCheck, 'success');
  static const warning = AppIconData._(FLucideIcons.triangleAlert, 'warning');
  static const error = AppIconData._(FLucideIcons.circleAlert, 'error');
  static const info = AppIconData._(FLucideIcons.info, 'info');
  static const security = AppIconData._(FLucideIcons.shieldCheck, 'security');
  static const devices = AppIconData._(
    FLucideIcons.monitorSmartphone,
    'devices',
  );
  static const empty = AppIconData._(FLucideIcons.inbox, 'empty');
  static const retry = AppIconData._(FLucideIcons.rotateCw, 'retry');
  static const close = AppIconData._(FLucideIcons.x, 'close');
  static const send = AppIconData._(FLucideIcons.send, 'send');
  static const attach = AppIconData._(FLucideIcons.paperclip, 'attach');
  static const emoji = AppIconData._(FLucideIcons.smile, 'emoji');
  static const keyboard = AppIconData._(FLucideIcons.keyboard, 'keyboard');
  static const more = AppIconData._(FLucideIcons.ellipsisVertical, 'more');
  static const pin = AppIconData._(FLucideIcons.pin, 'pin');
  static const reply = AppIconData._(
    FLucideIcons.reply,
    'reply',
    mirrorsInRtl: true,
  );
  static const edit = AppIconData._(FLucideIcons.pencil, 'edit');
  static const delete = AppIconData._(FLucideIcons.trash2, 'delete');
  static const copy = AppIconData._(FLucideIcons.copy, 'copy');
  static const star = AppIconData._(FLucideIcons.star, 'star');
  static const muted = AppIconData._(FLucideIcons.bellOff, 'muted');
  static const notifications = AppIconData._(
    FLucideIcons.bell,
    'notifications',
  );
  // The second tick means *seen*, and nothing else is allowed to draw it.
  // Arrival and reading are different claims about different people — one is
  // about a device, the other about a person — and a reader who has learned
  // that two ticks means somebody read their message will not re-learn it for
  // this application. Both arrival states are one tick, told apart by colour
  // and by the label every one of them carries.
  static const accepted = AppIconData._(FLucideIcons.check, 'accepted');
  static const delivered = AppIconData._(FLucideIcons.check, 'delivered');
  static const read = AppIconData._(FLucideIcons.checkCheck, 'read');
  static const jumpDown = AppIconData._(
    FLucideIcons.arrowDown,
    'jumpDown',
    mirrorsInRtl: true,
  );
  static const clock = AppIconData._(FLucideIcons.clock3, 'clock');
  static const saved = AppIconData._(FLucideIcons.bookmark, 'saved');
  static const unsupported = AppIconData._(
    FLucideIcons.fileQuestion,
    'unsupported',
  );
  static const offlineQueue = AppIconData._(
    FLucideIcons.cloudOff,
    'offlineQueue',
  );
}

/// App-owned icon renderer with intentional directional mirroring.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.data, {
    this.color,
    this.decorative = true,
    this.semanticLabel,
    this.size = 24,
    super.key,
  }) : assert(
         decorative || semanticLabel != null,
         'A meaningful icon requires a semantic label.',
       );

  final AppIconData data;
  final Color? color;
  final bool decorative;
  final String? semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mirrored =
        data.mirrorsInRtl && Directionality.of(context) == TextDirection.rtl;
    final icon = Transform.flip(
      key: ValueKey('app-icon-${data.debugName}-${mirrored ? 'rtl' : 'ltr'}'),
      flipX: mirrored,
      child: Icon(data.icon, color: color, size: size),
    );

    return Semantics(
      container: !decorative,
      label: decorative ? null : semanticLabel,
      excludeSemantics: true,
      child: icon,
    );
  }
}
