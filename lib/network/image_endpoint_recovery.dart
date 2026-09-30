import 'dart:io';

import 'package:dio/dio.dart';

const imageFastFailoverEnabled =
    bool.fromEnvironment('FE_IMAGE_FAST_FAILOVER', defaultValue: true);

/// Temporary, exact-endpoint avoidance, not a persistent domain blacklist.
/// Normal TLS is retried after expiry, allowing endpoint or network recovery.
/// Proxy routes are isolated and no URL paths/credentials are logged.
class ImageEndpointRecovery {
  ImageEndpointRecovery({
    this.fastFailover = imageFastFailoverEnabled,
    this.cooldown = const Duration(seconds: 60),
    this.capacity = 128,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final bool fastFailover;
  final Duration cooldown;
  final int capacity;
  final DateTime Function() _now;
  final _failed = <String, DateTime>{};

  static Object cause(Object error) =>
      error is DioException && error.error != null
          ? cause(error.error!)
          : error;

  static bool wrongVersion(Object error) {
    final inner = cause(error);
    return inner is HandshakeException &&
        RegExp(r'wrong[_ ]version[_ ]number', caseSensitive: false)
            .hasMatch(inner.toString());
  }

  bool needsNewSource(Object error) =>
      fastFailover &&
      (cause(error) is ImageEndpointUnavailable || wrongVersion(error));

  String _key(Uri uri, String proxy) =>
      '$proxy\u0000${uri.scheme}://${uri.host}:${uri.port}';

  void _prune() => _failed.removeWhere((_, expiry) => !expiry.isAfter(_now()));

  void clear() => _failed.clear();

  bool shouldAvoid(Uri uri, String proxy) {
    _prune();
    return fastFailover && _failed.containsKey(_key(uri, proxy));
  }

  void failed(Uri uri, String proxy) {
    // A site/fullimg URL may redirect to an image host before TLS fails.
    // Never quarantine the whole gallery/API origin based on that failure.
    if (!fastFailover ||
        uri.scheme != 'https' ||
        !uri.host.endsWith('.hath.network')) {
      return;
    }
    _prune();
    _failed.remove(_key(uri, proxy));
    while (_failed.length >= capacity && _failed.isNotEmpty) {
      _failed.remove(_failed.keys.first);
    }
    if (capacity > 0) {
      _failed[_key(uri, proxy)] = _now().add(cooldown);
    }
  }
}

final imageEndpointRecovery = ImageEndpointRecovery();

/// A bounded page operation should resolve another source, not keep connecting
/// to this endpoint. Deliberately contains no original signed URL or exception.
class ImageEndpointUnavailable extends HttpException {
  const ImageEndpointUnavailable()
      : super('Image endpoint temporarily unavailable');
}
