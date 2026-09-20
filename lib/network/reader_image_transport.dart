import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/network/image_transfer_adapter.dart';

class ReaderImageHttpException implements Exception {
  const ReaderImageHttpException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Image request failed (HTTP $statusCode)';
}

/// Owns its transport so deadlines bound all request phases and close its
/// client without closing unrelated reader or preloader requests.
class ReaderImageTransport {
  const ReaderImageTransport({
    this.headerTimeout = const Duration(seconds: 5),
    this.idleTimeout = const Duration(seconds: 20),
    this.totalTimeout = const Duration(minutes: 2),
  });

  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration totalTimeout;

  Future<Uint8List> fetch(
    String url, {
    required String proxy,
    required String phase,
    int? gid,
    int? page,
    void Function(int, int?)? onProgress,
    DownloadDiagnostics? diagnostics,
  }) async {
    var currentUri = Uri.parse(url);
    final dio = Dio(BaseOptions(
      connectTimeout: headerTimeout,
      receiveTimeout: idleTimeout,
      sendTimeout: headerTimeout,
      responseType: ResponseType.stream,
      followRedirects: false,
      extra: {'feImagePhase': phase},
      validateStatus: (_) => true,
    ))
      ..httpClientAdapter = ImageTransferAdapter(
        proxy: proxy,
        // Retain the pre-existing reader trust policy; never use TLS version
        // downgrades or plaintext fallback as a handshake-error workaround.
        skipCertificate: true,
        diagnostics: diagnostics,
      );
    final watch = Stopwatch()..start();
    int redirects = 0;
    int received = 0;
    int? status;
    String stage = 'connect_headers';

    void record(String event, [Object? error]) {
      diagnostics?.record(event, gid: gid, page: page, details: {
        'phase': phase,
        'reason': stage,
        ...DownloadDiagnostics.endpoint(currentUri.toString()),
        'adapter': 'scoped_proxy_io',
        'proxy_type': DownloadDiagnostics.proxyType(proxy),
        'elapsed_ms': watch.elapsedMilliseconds,
        'redirect_count': redirects,
        'bytes': received,
        if (status != null) 'http_status': status,
        if (error != null) ...DownloadDiagnostics.failure(error),
      });
    }

    Future<Response<ResponseBody>> responseHeaders() async {
      while (true) {
        if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
          throw const FormatException('Unsupported image URL scheme');
        }
        record('reader_network_start');
        final response = await dio.get<ResponseBody>(currentUri.toString());
        status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (const {301, 302, 303, 307, 308}.contains(status) &&
            location != null) {
          if (++redirects > 5) {
            throw const HttpException('Too many image redirects');
          }
          final next = currentUri.resolve(location);
          if (currentUri.scheme == 'https' && next.scheme != 'https') {
            throw const FormatException('Insecure image redirect');
          }
          await response.data!.stream.drain<void>();
          currentUri = next;
          continue;
        }
        return response;
      }
    }

    Future<Uint8List> transfer() async {
      final response = await responseHeaders().timeout(
        headerTimeout,
        onTimeout: () {
          dio.close(force: true);
          throw TimeoutException('Image connection/headers timed out');
        },
      );
      if (response.statusCode != HttpStatus.ok) {
        throw ReaderImageHttpException(response.statusCode!);
      }
      stage = 'body';
      final contentLength = int.tryParse(
          response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
      // The HTTP client decompresses encoded bodies; their wire length is not
      // a valid total for the decompressed progress events.
      final total =
          response.headers.value(HttpHeaders.contentEncodingHeader) == null
              ? contentLength
              : null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream.timeout(idleTimeout)) {
        bytes.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      if (received == 0) throw const HttpException('Empty image response');
      return bytes.takeBytes();
    }

    try {
      final bytes = await transfer().timeout(
        totalTimeout,
        onTimeout: () {
          dio.close(force: true);
          throw TimeoutException('Image request deadline exceeded');
        },
      );
      record('reader_network_complete');
      return bytes;
    } catch (error, stack) {
      final cause = error is DioException
          ? (const {
              DioExceptionType.connectionTimeout,
              DioExceptionType.sendTimeout,
              DioExceptionType.receiveTimeout,
            }.contains(error.type)
              ? TimeoutException('Image request timed out')
              : error.error ?? error)
          : error;
      record('reader_network_error', cause);
      Error.throwWithStackTrace(cause, stack);
    } finally {
      dio.close(force: true);
    }
  }
}
