import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/common/global.dart';
import 'package:eros_fe/network/image_endpoint_recovery.dart';
import 'package:eros_fe/network/image_retry_policy.dart';
import 'package:eros_fe/network/reader_image_cache.dart';
import 'package:eros_fe/network/reader_image_transport.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const kReaderSourceRetries = 1;
const kReaderRequestRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// Reader + preload share the same representation keys and read legacy
/// extended-image entries. Downloaded/offline image paths remain unchanged.
/// Failed loads propagate their original exception, not "null".
@immutable
class ReaderImageProvider extends ImageProvider<ReaderImageProvider>
    with ExtendedImageProvider<ReaderImageProvider> {
  const ReaderImageProvider(
    this.url, {
    required this.cacheKey,
    this.cacheSpec,
    this.gid,
    this.page,
    this.phase = 'reader',
    this.transport = const ReaderImageTransport(),
    this.retryPolicy =
        const ImageRetryPolicy(delays: kReaderRequestRetryDelays),
    this.proxy,
  });

  final String url;
  final String cacheKey;
  final ReaderCacheSpec? cacheSpec;
  final int? gid;
  final int? page;
  final String phase;
  final ReaderImageTransport transport;
  final ImageRetryPolicy retryPolicy;
  final String? proxy;

  @override
  bool get cacheRawData => false;
  @override
  String? get imageCacheName => null;

  Future<File> _cacheFile() async {
    // Custom keys (legacy or representation-based) are not hashed again.
    if (cacheKey.isEmpty || path.basename(cacheKey) != cacheKey) {
      throw const FormatException('Invalid image cache key');
    }
    return File(path.join(
        (await getTemporaryDirectory()).path, cacheImageFolderName, cacheKey));
  }

  Future<Uint8List?> _cachedBytes() async {
    return readReaderImageCache(url: url, cacheKey: cacheKey, spec: cacheSpec);
  }

  Future<void> _saveCache(Uint8List bytes) async {
    File? temporary;
    try {
      // Never publish bytes under a representation key they do not match.
      if (cacheSpec != null && !await cacheSpec!.matches(bytes)) {
        activeDownloadDiagnostics?.record('reader_cache_write_skipped',
            gid: gid,
            page: page,
            details: {'phase': phase, 'reason': 'dimensions_mismatch'});
        return;
      }
      final target = await _cacheFile();
      await target.parent.create(recursive: true);
      // A reader and preloader may finish concurrently. Publish only complete
      // files; a download must never observe a half-written reader cache.
      final dir = await target.parent.createTemp('.write-');
      temporary = File(path.join(dir.path, 'image'));
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } on FileSystemException {
      activeDownloadDiagnostics?.record('reader_cache_write_failed',
          gid: gid, page: page, details: {'phase': phase});
      // A full/unavailable cache must not prevent displaying the image.
    } finally {
      try {
        if (temporary != null && await temporary.parent.exists()) {
          await temporary.parent.delete(recursive: true);
        }
      } on FileSystemException {
        // Cache cleanup is best-effort and must not hide a successful image.
      }
    }
  }

  Future<Uint8List> _networkBytes(StreamController<ImageChunkEvent>? chunks,
      {bool useCache = true}) async {
    for (int failures = 0;;) {
      // A preload/download may have populated the same cache during backoff.
      final cached = useCache ? await _cachedBytes() : null;
      if (cached != null) return cached;
      try {
        return await transport.fetch(
          url,
          proxy: proxy ?? globalDioConfig.proxy ?? 'DIRECT',
          phase: phase,
          gid: gid,
          page: page,
          diagnostics: activeDownloadDiagnostics,
          onProgress: (count, total) => chunks?.add(ImageChunkEvent(
            cumulativeBytesLoaded: count,
            expectedTotalBytes: total,
          )),
        );
      } catch (error) {
        // Let the UI's single source change run now instead of spending the
        // whole retry budget on the same known-bad URL.
        if (imageEndpointRecovery.needsNewSource(error)) rethrow;
        failures++;
        final transient = error is ReaderImageHttpException
            ? ImageRetryPolicy.retryableStatus(error.statusCode)
            : ImageRetryPolicy.isTransient(error);
        if (!transient || failures > retryPolicy.delays.length) rethrow;
        activeDownloadDiagnostics
            ?.record('reader_retry', gid: gid, page: page, details: {
          'phase': phase,
          'attempt': failures,
          'max_attempts': retryPolicy.maxAttempts,
          'delay_ms': retryPolicy.delays[failures - 1].inMilliseconds,
          ...DownloadDiagnostics.failure(error),
        });
        await retryPolicy.wait(failures, null);
      }
    }
  }

  Future<ui.Codec> _load(StreamController<ImageChunkEvent> chunks,
      ImageDecoderCallback decode) async {
    try {
      bool corruptCache = false;
      final cached = await _cachedBytes();
      if (cached != null) {
        try {
          return await instantiateImageCodec(cached, decode);
        } catch (_) {
          corruptCache = true;
          // Remove only this corrupt entry, never the user's whole cache.
          await clearDiskCachedImage(url, cacheKey: cacheKey);
        }
      }
      final bytes = await _networkBytes(chunks, useCache: !corruptCache);
      final codec = await instantiateImageCodec(bytes, decode);
      await _saveCache(bytes);
      return codec;
    } catch (error) {
      scheduleMicrotask(() => imageCache.evict(this));
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      ReaderImageProvider key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(chunks, decode),
      scale: 1,
      chunkEvents: chunks.stream,
      // Never put a signed image URL in error/debug labels.
      debugLabel: 'reader-image',
    );
  }

  // Context/phase deliberately do not split the preload and reader cache.
  @override
  bool operator ==(Object other) =>
      other is ReaderImageProvider &&
      url == other.url &&
      cacheKey == other.cacheKey &&
      proxy == other.proxy;

  @override
  int get hashCode => Object.hash(url, cacheKey, proxy);
}
