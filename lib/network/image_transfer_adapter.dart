import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';

/// Owns each image's HTTP client so aborting one request never aborts another.
/// close(force: true) aborts established requests and cancels connection tasks.
/// The SDK can still defer disposal of a socket inside a stalled TLS handshake;
/// bounded page retries are required independently of that low-level behavior.
class ImageTransferAdapter implements HttpClientAdapter {
  ImageTransferAdapter({required this.proxy, required this.skipCertificate});
  final String proxy;
  final bool skipCertificate;
  final _active = <IOHttpClientAdapter>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (_closed) throw StateError('Image adapter is closed');
    final adapter = IOHttpClientAdapter(createHttpClient: () {
      final client = createProxyHttpClient();
      client.findProxy = (_) => proxy.isEmpty ? 'DIRECT' : proxy;
      if (skipCertificate) {
        client.badCertificateCallback = (_, __, ___) => true;
      }
      return client;
    });
    _active.add(adapter);
    void finish() {
      _active.remove(adapter);
      adapter.close(force: true);
    }

    final weak = WeakReference(adapter);
    cancelFuture?.then((_) {
      final active = weak.target;
      if (active != null) {
        _active.remove(active);
        active.close(force: true);
      }
    });
    try {
      final body = await adapter.fetch(options, requestStream, cancelFuture);
      Stream<Uint8List> releaseAfterBody() async* {
        try {
          yield* body.stream;
        } finally {
          finish();
        }
      }

      return ResponseBody(
        releaseAfterBody(),
        body.statusCode,
        headers: body.headers,
        statusMessage: body.statusMessage,
        isRedirect: body.isRedirect,
        redirects: body.redirects,
        onClose: finish,
      )..extra = body.extra;
    } catch (_) {
      finish();
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final adapter in _active.toList()) {
      adapter.close(force: true);
    }
    _active.clear();
  }
}
