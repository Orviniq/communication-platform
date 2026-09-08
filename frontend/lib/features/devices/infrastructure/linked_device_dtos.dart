import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/features/devices/domain/linked_device_model.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';

final class OwnDeviceListResponseDto {
  const OwnDeviceListResponseDto(this.refresh);

  factory OwnDeviceListResponseDto.fromResponse(
    Object? value,
    Map<String, List<String>> headers,
  ) {
    if (value == null) {
      return const OwnDeviceListResponseDto(OwnDevicesNotModified());
    }
    final json = requireJsonObject(value);
    final values = json['devices'];
    final head = json['log_head_seq'];
    final etagValues = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'etag')
        .expand((entry) => entry.value)
        .toList(growable: false);
    if (values is! List<Object?> ||
        values.length > 10 ||
        (head != null && (head is! int || head < 0)) ||
        etagValues.length != 1 ||
        !_validEtag(etagValues.single)) {
      throw const MalformedApiBody();
    }
    final devices = values.map(_device).toList(growable: false);
    final ids = devices.map((device) => device.deviceId).toSet();
    if (ids.length != devices.length ||
        devices.where((device) => device.thisDevice).length != 1) {
      throw const MalformedApiBody();
    }
    return OwnDeviceListResponseDto(
      OwnDevicesUpdated(
        devices: devices,
        etag: etagValues.single,
        logHeadSequence: head as int?,
      ),
    );
  }

  final OwnDeviceRefresh refresh;

  static LinkedDevice _device(Object? value) {
    final json = requireJsonObject(value);
    final id = json['device_id'];
    final label = json['label_blob'];
    final created = _date(json['created_date']);
    final current = json['this_device'];
    Uint8List? labelBytes;
    if (label != null) {
      if (label is! String) throw const MalformedApiBody();
      try {
        labelBytes = Uint8List.fromList(base64Decode(label));
      } on FormatException {
        throw const MalformedApiBody();
      }
      if ((labelBytes.length != 256 && labelBytes.length != 1024) ||
          base64Encode(labelBytes) != label) {
        throw const MalformedApiBody();
      }
    }
    if (id is! String || !_uuid.hasMatch(id) || current is! bool) {
      throw const MalformedApiBody();
    }
    return LinkedDevice(
      deviceId: id.toLowerCase(),
      label: null,
      labelState: labelBytes == null
          ? LinkedDeviceLabelState.notSet
          : LinkedDeviceLabelState.unreadable,
      createdDate: created,
      thisDevice: current,
      encryptedLabel: labelBytes,
    );
  }

  static DateTime _date(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const MalformedApiBody();
    }
    final parsed = DateTime.tryParse('${value}T00:00:00.000Z');
    if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
      throw const MalformedApiBody();
    }
    return parsed;
  }

  static bool _validEtag(String value) =>
      value.length >= 3 &&
      value.length <= 130 &&
      value.startsWith('"') &&
      value.endsWith('"');
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
