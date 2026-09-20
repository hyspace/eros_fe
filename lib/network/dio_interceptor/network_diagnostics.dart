import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';

/// Opt-in endpoint-only telemetry, never request headers/bodies/paths.
class NetworkDiagnosticsInterceptor extends Interceptor {
  NetworkDiagnosticsInterceptor({required this.adapter, required this.proxy});
  final String adapter;
  final String? proxy;
  final _started = Expando<Stopwatch>();

  Map<String, Object?> _details(RequestOptions options) => {
        'phase': options.extra['feImageTransfer'] == true ? 'download' : 'api',
        'adapter':
            options.extra['feImageTransfer'] == true && adapter == 'proxy_io'
                ? 'scoped_proxy_io'
                : adapter,
        'proxy_type': DownloadDiagnostics.proxyType(proxy),
        ...DownloadDiagnostics.endpoint(options.uri.toString()),
        if (_started[options] != null)
          'elapsed_ms': _started[options]!.elapsedMilliseconds,
      };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (activeDownloadDiagnostics != null) {
      _started[options] = Stopwatch()..start();
      activeDownloadDiagnostics?.record('http_request',
          details: _details(options));
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    activeDownloadDiagnostics?.record('http_response', details: {
      ..._details(response.requestOptions),
      ...DownloadDiagnostics.endpoint(response.realUri.toString()),
      'redirect_count': response.redirects.length,
      'http_status': response.statusCode,
    });
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    activeDownloadDiagnostics?.record('http_error', details: {
      ..._details(error.requestOptions),
      ...DownloadDiagnostics.failure(error),
    });
    handler.next(error);
  }
}
