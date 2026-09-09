import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_platform/core/protocol/beta_mls_model.dart';
import 'package:communication_platform/features/groups/domain/group_key_package_model.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_dtos.dart';
import 'package:communication_platform/features/networking/infrastructure/api/api_request.dart';

final class GroupKeyPackageCountResponseDto {
  const GroupKeyPackageCountResponseDto(this.count);

  factory GroupKeyPackageCountResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final count = json['keypackage_count'];
    if (json.length != 1 || count is! int || count < 0 || count > 100) {
      throw const MalformedApiBody();
    }
    return GroupKeyPackageCountResponseDto(count);
  }

  final int count;
}

final class ClaimedGroupKeyPackagesResponseDto {
  const ClaimedGroupKeyPackagesResponseDto(this.packages);

  factory ClaimedGroupKeyPackagesResponseDto.fromJson(Object? value) {
    final json = requireJsonObject(value);
    final rows = json['keypackages'];
    if (json.length != 1 || rows is! List<Object?> || rows.length > 100) {
      throw const MalformedApiBody();
    }
    final ids = <String>{};
    final packages = rows
        .map((value) {
          final row = requireJsonObject(value);
          final deviceId = row['device_id'];
          final blob = row['blob'];
          if (row.length != 2 ||
              deviceId is! String ||
              !_uuid.hasMatch(deviceId) ||
              !ids.add(deviceId.toLowerCase()) ||
              blob is! String ||
              !isCanonicalBase64Bucket(
                blob,
                ApiContractLimits.keyPackageBuckets,
              )) {
            throw const MalformedApiBody();
          }
          try {
            return ClaimedGroupKeyPackage(
              deviceId: deviceId.toLowerCase(),
              wrappedKeyPackage: Uint8List.fromList(base64Decode(blob)),
            );
          } on Object {
            throw const MalformedApiBody();
          }
        })
        .toList(growable: false);
    return ClaimedGroupKeyPackagesResponseDto(List.unmodifiable(packages));
  }

  final List<ClaimedGroupKeyPackage> packages;
}

Map<String, Object?> groupKeyPackageUploadJson(GroupKeyPackageUpload upload) =>
    <String, Object?>{
      'keypackages': [
        for (final package in upload.wrappedKeyPackages) base64Encode(package),
      ],
      'is_last_resort': upload.kind == MlsKeyPackageKind.lastResort,
    };

/// [claimMax] is `claim_max` from `GET /api/v1/config`, the ceiling the claim
/// route enforces on one body.
Map<String, Object?> groupKeyPackageClaimJson(
  List<String>? deviceIds, {
  required int claimMax,
}) {
  if (deviceIds == null) return const {};
  if (deviceIds.length > claimMax ||
      deviceIds.toSet().length != deviceIds.length ||
      deviceIds.any((id) => !_uuid.hasMatch(id))) {
    throw const GroupKeyPackageFormatException();
  }
  return <String, Object?>{
    'device_ids': [for (final id in deviceIds) id.toLowerCase()],
  };
}

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
