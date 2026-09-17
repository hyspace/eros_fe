import 'dart:convert';

// Local packaging only. Both default to false in ordinary/upstream builds.
const localRecoveryEnabled = bool.fromEnvironment('FE_LOCAL_RECOVERY');
const localRecoveryTest = bool.fromEnvironment('FE_RECOVERY_TEST');

Map<String, dynamic>? recoveryNote(String? text) {
  if (!localRecoveryEnabled || text == null || text.isEmpty) return null;
  try {
    final value = jsonDecode(text);
    if (value is Map && value['feLocalRecovery'] is Map) {
      return Map<String, dynamic>.from(value['feLocalRecovery'] as Map);
    }
  } catch (_) {
    // Existing opaque application data is not a recovery marker.
  }
  return null;
}

String recoveryWarning(String? text) {
  final note = recoveryNote(text);
  if (note == null) return '';
  if (note['expectedPageCountKnown'] == false) {
    return '仅本地文件 · 原总页数未知';
  }
  final missing = note['missingPages'] as int? ?? 0;
  return missing > 0 ? '本地恢复 · 缺 $missing 页' : '';
}
