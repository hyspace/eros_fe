import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/network/image_endpoint_recovery.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';

/// Owns each image's HTTP client so aborting one request never aborts another.
/// close(force: true) aborts established requests and cancels connection tasks.
/// The SDK can still defer disposal of a socket inside a stalled TLS handshake;
/// bounded page retries are required independently of that low-level behavior.
class ImageTransferAdapter implements HttpClientAdapter {
  ImageTransferAdapter({
    required this.proxy,
    required this.skipCertificate,
    ImageEndpointRecovery? recovery,
    this.normalAdapterFactory,
    this.diagnostics,
  }) : recovery = recovery ?? imageEndpointRecovery;
  final String proxy;
  final bool skipCertificate;
  final ImageEndpointRecovery recovery;
  final HttpClientAdapter Function()? normalAdapterFactory;
  final DownloadDiagnostics? diagnostics;
  final _active = <HttpClientAdapter>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (_closed) {
      throw StateError('Image adapter is closed');
    }
    bool cancelled = false;
    cancelFuture?.then((_) => cancelled = true);
    void checkCancelled() {
      if (cancelled || _closed) {
        throw DioException(
            requestOptions: options, type: DioExceptionType.cancel);
      }
    }

    void record(String event, [Map<String, Object?> details = const {}]) {
      (diagnostics ?? activeDownloadDiagnostics)?.record(event, details: {
        ...DownloadDiagnostics.endpoint(options.uri.toString()),
        'phase': options.extra['feImagePhase'] ?? 'download',
        'proxy_type': DownloadDiagnostics.proxyType(proxy),
        ...details,
      });
    }

    if (recovery.shouldAvoid(options.uri, proxy)) {
      record('image_host_avoided', {'reason': 'cooldown'});
      throw const ImageEndpointUnavailable();
    }
    try {
      return await _normalFetch(options, requestStream, cancelFuture);
    } catch (error) {
      checkCancelled();
      if (!ImageEndpointRecovery.wrongVersion(error)) {
        rethrow;
      }
      recovery.failed(options.uri, proxy);
      if (recovery.shouldAvoid(options.uri, proxy)) {
        record('image_host_cooldown');
      }
      // Preserve the initial TLS cause for diagnostics and fast source change.
      rethrow;
    }
  }

  Future<ResponseBody> _normalFetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final adapter = normalAdapterFactory?.call() ??
        IOHttpClientAdapter(createHttpClient: () {
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
