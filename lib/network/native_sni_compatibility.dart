import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

abstract class SniCompatibilityTransport {
  bool get supported;
  Future<ResponseBody> fetch(
      RequestOptions options, Future<void>? cancelFuture);
  void close();
}

/// Android-only, bounded streaming bridge. No files, cookies, proxy bypass or
/// global HttpOverrides. Removing this file/bridge leaves normal IO untouched.
class NativeSniCompatibility implements SniCompatibilityTransport {
  static const channel = MethodChannel('fehviewer/image_sni_compat');
  static int _serial = 0;
  final _active = <String>{};
  bool _closed = false;

  @override
  bool get supported => Platform.isAndroid;

  Future<void> _release(String id) async {
    if (!_active.remove(id)) {
      return;
    }
    try {
      await channel.invokeMethod<void>('cancel', {'id': id});
    } on PlatformException {
      // Cleanup must not hide the original error.
    } on MissingPluginException {
      // Older/native-less builds use the normal source-change path instead.
    }
  }

  void _checkActive(String id, RequestOptions options) {
    if (_closed || !_active.contains(id)) {
      throw DioException(
          requestOptions: options, type: DioExceptionType.cancel);
    }
  }

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Future<void>? cancelFuture) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${++_serial}';
    _active.add(id);
    cancelFuture?.then((_) => _release(id));
    try {
      _checkActive(id, options);
      final headers = <String, String>{};
      // Signed H@H image URLs do not need account cookies or authorization.
      for (final entry in options.headers.entries) {
        if (const {'accept', 'accept-language', 'user-agent'}
            .contains(entry.key.toLowerCase())) {
          headers[entry.key] = '${entry.value}';
        }
      }
      final result = await channel.invokeMapMethod<String, dynamic>('start', {
        'id': id,
        'url': options.uri.toString(),
        'headers': headers,
        'connect_ms':
            (options.connectTimeout?.inMilliseconds ?? 5000).clamp(1, 10000),
        'read_ms':
            (options.receiveTimeout?.inMilliseconds ?? 20000).clamp(1, 20000),
        'total_ms': 120000,
      }).timeout(Duration(
          milliseconds: (options.connectTimeout?.inMilliseconds ?? 5000)
              .clamp(1, 10000)));
      _checkActive(id, options);
      if (result == null) {
        throw const HttpException('Missing compatibility response');
      }
      final status = result['status'] as int;
      // Do not follow a redirect with a different trust/transport policy.
      if (status >= 300 && status < 400) {
        throw const HttpException('Compatibility source requires a new URL');
      }
      final responseHeaders = (result['headers'] as Map).map(
        (key, value) => MapEntry('$key', (value as List).cast<String>()),
      );
      Stream<Uint8List> body() async* {
        try {
          while (true) {
            _checkActive(id, options);
            final bytes =
                await channel.invokeMethod<Uint8List>('read', {'id': id});
            _checkActive(id, options);
            if (bytes == null || bytes.isEmpty) {
              break;
            }
            yield bytes;
          }
        } on PlatformException {
          _checkActive(id, options);
          // A native read timeout/disconnect is a retryable transport failure,
          // not a permanent plugin/programming error.
          throw const HttpException('Compatibility image stream failed');
        } finally {
          await _release(id);
        }
      }

      return ResponseBody(body(), status,
          headers: responseHeaders, onClose: () => unawaited(_release(id)));
    } catch (_) {
      await _release(id);
      rethrow;
    }
  }

  @override
  void close() {
    _closed = true;
    for (final id in _active.toList()) {
      unawaited(_release(id));
    }
  }
}
