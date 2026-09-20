import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/reader_image_cache.dart';
import 'package:extended_image/extended_image.dart';

const downloadDiagnosticsEnabled =
    bool.fromEnvironment('FE_DOWNLOAD_DIAGNOSTICS');

DownloadDiagnostics? activeDownloadDiagnostics;

/// Opt-in, bounded diagnostic log independent of the application's log level.
/// Never records image URLs, page URLs, filenames, cookies or raw exceptions.
class DownloadDiagnostics {
  DownloadDiagnostics(this.file, {this.maxBytes = 1024 * 1024});

  final File file;
  final int maxBytes;
  Future<void> _pending = Future<void>.value();
  int writeFailures = 0;

  static const _allowedDetails = {
    'phase',
    'reason',
    'key_type',
    'key_hash',
    'bytes',
    'retry',
    'original',
    'has_url',
    'has_href',
    'has_origin',
    'disk_cached',
    'page_count',
    'completed',
    'known_urls',
    'attempt',
    'source_change',
    'scheme',
    'host',
    'port',
    'exception',
    'dio_type',
    'tls_error',
    'http_status',
    'max_attempts',
    'delay_ms',
    'failed_pages',
    'adapter',
    'proxy_type',
    'elapsed_ms',
    'redirect_count',
    'os_error_code',
  };

  void record(
    String event, {
    int? gid,
    int? page,
    Map<String, Object?> details = const {},
  }) {
    final line = '${jsonEncode({
          'time': DateTime.now().toUtc().toIso8601String(),
          'event': event,
          if (gid != null) 'gid': gid,
          if (page != null) 'page': page,
          for (final entry in details.entries)
            if (_allowedDetails.contains(entry.key)) entry.key: entry.value,
        })}\n';
    _pending = _pending.then((_) async {
      await file.parent.create(recursive: true);
      if (await file.exists() && await file.length() >= maxBytes) {
        final previous = File('${file.path}.previous.log');
        if (await previous.exists()) {
          await previous.delete();
        }
        await file.rename(previous.path);
      }
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    }).catchError((Object error) {
      // Diagnostics must never fail a download or create an unhandled Future.
      writeFailures++;
    });
  }

  Future<void> flush() => _pending;

  static Map<String, Object?> endpoint(String url) {
    try {
      final uri = Uri.tryParse(url);
      return {
        if (uri != null) 'scheme': uri.scheme,
        if (uri != null) 'host': uri.host,
        if (uri != null) 'port': uri.port,
      };
    } on FormatException {
      return {};
    }
  }

  /// Never include proxy hosts, usernames or passwords in diagnostics.
  static String proxyType(String? proxy) {
    final type = (proxy ?? '').trim().split(RegExp(r'\s+')).first.toUpperCase();
    return const {'DIRECT', 'PROXY', 'SOCKS4', 'SOCKS5'}.contains(type)
        ? type.toLowerCase()
        : 'unspecified';
  }

  static Map<String, Object?> failure(Object error) {
    final cause = error is DioException ? error.error ?? error : error;
    // BoringSSL's code is often in OSError, not HandshakeException.message.
    // Inspect the string for a fixed classification, but never persist it.
    final tls = cause is HandshakeException ? cause.toString() : '';
    return {
      'exception': cause.runtimeType.toString(),
      if (error is DioException) 'dio_type': error.type.name,
      if (error is DioException) 'http_status': error.response?.statusCode,
      if (cause is SocketException) 'os_error_code': cause.osError?.errorCode,
      if (cause is HandshakeException)
        'tls_error': tls.contains('WRONG_VERSION_NUMBER')
            ? 'wrong_version_number'
            : (tls.contains('CERTIFICATE_VERIFY_FAILED')
                ? 'certificate_verify_failed'
                : 'handshake_failed'),
    };
  }
}

int? diagnosticGalleryId(GalleryImage image) =>
    int.tryParse(image.gid ?? '') ??
    int.tryParse(
        RegExp(r'/(\d+)-\d+').firstMatch(image.href ?? '')?.group(1) ?? '');

/// Correlate the reader's actual key and on-disk presence with later downloads.
/// Only runs in a diagnostic build; inspecting a cache never downloads an image.
Future<void> recordReaderCache(
  GalleryImage image, {
  required String phase,
}) async {
  final diagnostics = activeDownloadDiagnostics;
  final url = image.imageUrl;
  if (diagnostics == null || url == null || url.isEmpty) {
    return;
  }
  try {
    final key = image.getCacheKey(url);
    String? keyType;
    final bytes = await readReaderImageCache(
      url: url,
      cacheKey: key,
      spec: image.getCacheSpec(url),
      onLookup: (type, outcome, _) {
        if (outcome == 'found') {
          keyType = type;
        }
      },
    );
    diagnostics.record(
      'reader_ready',
      gid: diagnosticGalleryId(image),
      page: image.ser,
      details: {
        'phase': phase,
        'key_hash': keyToMd5(key),
        if (keyType != null) 'key_type': keyType,
        'original': url == image.originImageUrl,
        'disk_cached': bytes != null,
      },
    );
  } catch (_) {
    diagnostics.record('reader_probe_failed', page: image.ser);
  }
}
