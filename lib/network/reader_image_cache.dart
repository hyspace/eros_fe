import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eros_fe/models/gallery_image.dart';
import 'package:extended_image/extended_image.dart' show keyToMd5;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// A page's resampled representation, not the address of its current host.
/// Missing xres is deliberately NOT interpreted as a particular resolution.
class ReaderCacheSpec {
  ReaderCacheSpec.fromImage(GalleryImage image, String url)
      : pageKey = Uri.encodeComponent(image.href ?? ''),
        original = url.isNotEmpty && url == image.originImageUrl,
        width = url == image.imageUrl ? _dimension(image.imageWidth) : null,
        height = url == image.imageUrl ? _dimension(image.imageHeight) : null,
        xres = RegExp(r'xres=(\d+)').firstMatch(url)?.group(1) ?? '';

  final String pageKey;
  final bool original;
  final int? width;
  final int? height;
  final String xres;

  static int? _dimension(double? value) => value != null &&
          value.isFinite &&
          value > 0 &&
          value == value.roundToDouble()
      ? value.toInt()
      : null;

  bool get hasDimensions =>
      !original && pageKey.isNotEmpty && width != null && height != null;

  String get legacyKey => '${pageKey}_${original ? 'origin' : xres}';
  String get key =>
      hasDimensions ? '${pageKey}_resampled_${width}x$height' : legacyKey;

  bool isLegacyAlias(String name) =>
      hasDimensions &&
      name.startsWith('${pageKey}_') &&
      RegExp(r'^\d*$').hasMatch(name.substring(pageKey.length + 1));

  Future<bool> matches(Uint8List bytes) async {
    if (!hasDimensions) {
      return true;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return descriptor.width == width && descriptor.height == height;
    } catch (_) {
      return false;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

// A large gallery must not enumerate the whole disk cache on every page/retry.
// Exact and common legacy keys are always checked live; this short-lived index
// is only for older xres tiers not inferable from the actual pixel width.
String? _indexedDirectory;
DateTime? _indexExpires;
Future<Map<String, List<String>>>? _legacyIndex;

Future<List<String>> _legacyAliases(Directory directory, String pageKey) async {
  if (_indexedDirectory != directory.path ||
      _indexExpires == null ||
      DateTime.now().isAfter(_indexExpires!)) {
    _indexedDirectory = directory.path;
    _indexExpires = DateTime.now().add(const Duration(seconds: 30));
    _legacyIndex = () async {
      final index = <String, List<String>>{};
      try {
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is! File) {
            continue;
          }
          final key = path.basename(entry.path);
          final split = key.lastIndexOf('_');
          if (split <= 0 ||
              !RegExp(r'^\d*$').hasMatch(key.substring(split + 1))) {
            continue;
          }
          index.putIfAbsent(key.substring(0, split), () => []).add(key);
        }
      } on FileSystemException {
        // Cache eviction during indexing is harmless.
      }
      return index;
    }();
  }
  return (await _legacyIndex!)[pageKey] ?? const [];
}

/// Reads both existing extended-image formats and dimension-validated aliases.
/// The shared directory index is only a migration fallback after direct lookups miss;
/// only numeric/empty suffixes for this exact page are considered, never
/// originals, other pages, or other new representation keys.
Future<Uint8List?> readReaderImageCache({
  required String url,
  String? cacheKey,
  ReaderCacheSpec? spec,
  void Function(String keyType, String outcome, int bytes)? onLookup,
}) async {
  final directory =
      Directory(path.join((await getTemporaryDirectory()).path, 'cacheimage'));
  final visited = <String>{};

  Future<Uint8List?> read(String key, String type) async {
    if (key.isEmpty || path.basename(key) != key || !visited.add(key)) {
      return null;
    }
    try {
      final file = File(path.join(directory.path, key));
      if (!await file.exists()) {
        onLookup?.call(type, 'missing', 0);
        return null;
      }
      final bytes = await file.readAsBytes();
      final mime = lookupMimeType('', headerBytes: bytes.take(12).toList());
      if (bytes.isEmpty || mime == null || !mime.startsWith('image/')) {
        onLookup?.call(
            type, bytes.isEmpty ? 'empty' : 'not_image', bytes.length);
        return null;
      }
      // Even an old exact key with empty xres can hold the wrong resolution.
      if (spec != null && !await spec.matches(bytes)) {
        onLookup?.call(type, 'dimensions_mismatch', bytes.length);
        return null;
      }
      onLookup?.call(type, 'found', bytes.length);
      return bytes;
    } on FileSystemException {
      onLookup?.call(type, 'read_error', 0);
      return null;
    }
  }

  if (cacheKey != null) {
    final bytes = await read(cacheKey, 'reader');
    if (bytes != null) {
      return bytes;
    }
  }
  if (spec?.hasDimensions ?? false) {
    // Common legacy keys without enumerating the directory.
    for (final key in {
      spec!.legacyKey,
      '${spec.pageKey}_',
      '${spec.pageKey}_${spec.width}',
    }) {
      final bytes = await read(key, 'reader_alias');
      if (bytes != null) {
        return bytes;
      }
    }
  }
  if (url.isNotEmpty) {
    final bytes = await read(keyToMd5(url), 'legacy');
    if (bytes != null) {
      return bytes;
    }
  }
  if (spec?.hasDimensions ?? false) {
    for (final key in await _legacyAliases(directory, spec!.pageKey)) {
      if (!spec.isLegacyAlias(key)) {
        continue;
      }
      final bytes = await read(key, 'reader_alias');
      if (bytes != null) {
        return bytes;
      }
    }
  }
  return null;
}
