import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:eros_fe/common/global.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/common/service/ehsetting_service.dart';
import 'package:eros_fe/network/api.dart';
import 'package:eros_fe/network/app_dio/app_dio.dart';
import 'package:eros_fe/network/app_dio/proxy.dart';
import 'package:eros_fe/network/reader_image_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => Logger.level = Level.off);
  tearDown(Get.reset);

  test('AppDio timeouts are milliseconds for both site configurations', () {
    Api.cacheOption = CacheOptions(store: MemCacheStore());
    Get.put<EhSettingService>(_Settings());
    for (final config in [ehDioConfig, exDioConfig]) {
      final dio = AppDio(dioConfig: config.copyWith(cookiesPath: ''));
      expect(dio.options.connectTimeout!.inMilliseconds, config.connectTimeout);
      expect(dio.options.sendTimeout!.inMilliseconds, config.sendTimeout);
      expect(dio.options.receiveTimeout!.inMilliseconds, config.receiveTimeout);
      dio.close(force: true);
    }
  });

  test('real reader transfer follows redirects and receives the entire body',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = Uint8List.fromList(List.generate(65536, (i) => i % 251));
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response
          ..statusCode = 302
          ..headers.set('location', '/image');
      } else {
        request.response
          ..statusCode = 200
          ..contentLength = payload.length;
        for (int offset = 0; offset < payload.length; offset += 4096) {
          request.response.add(payload.sublist(offset, offset + 4096));
          await request.response.flush();
        }
      }
      await request.response.close();
    });
    try {
      final progress = <int>[];
      final result = await const ReaderImageTransport().fetch(
        'http://127.0.0.1:${server.port}/redirect',
        proxy: 'DIRECT',
        phase: 'test',
        onProgress: (count, _) => progress.add(count),
      );
      expect(result, payload);
      expect(progress.last, payload.length);
    } finally {
      await server.close(force: true);
    }
  });

  test('real TLS failure diagnostics omit URL paths, queries and credentials',
      () async {
    final directory = await Directory.systemTemp.createTemp('tls-telemetry-');
    final diagnostics = DownloadDiagnostics(File('${directory.path}/log'));
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    server.listen((socket) {
      peers.add(socket);
      bool sent = false;
      socket.listen((_) {
        if (!sent) {
          sent = true;
          socket.write('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n');
        }
      }, onError: (_) {});
    });
    try {
      await expectLater(
        const ReaderImageTransport().fetch(
          'https://PRIVATE:PRIVATE@127.0.0.1:${server.port}/PRIVATE?key=PRIVATE',
          proxy: 'DIRECT',
          phase: 'test',
          diagnostics: diagnostics,
        ),
        throwsA(isA<HandshakeException>()),
      );
      await diagnostics.flush();
      final text = await diagnostics.file.readAsString();
      expect(text, isNot(contains('PRIVATE')));
      final events = const LineSplitter()
          .convert(text)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      final error =
          events.singleWhere((e) => e['event'] == 'reader_network_error');
      expect(error['tls_error'], 'wrong_version_number');
      expect(error['host'], '127.0.0.1');
      expect(error['port'], server.port);
    } finally {
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
      await directory.delete(recursive: true);
    }
  });

  test('cancelling one image does not abort another image on the same adapter',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final both = Completer<void>();
    int count = 0;
    server.listen((request) async {
      if (++count == 2) both.complete();
      if (request.uri.path == '/ok') {
        await both.future;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        request.response.write('ok');
        await request.response.close();
      }
    });
    final dio = Dio()..httpClientAdapter = HttpProxyAdapter(proxy: 'DIRECT');
    final token = CancelToken();
    final options = Options(extra: {'feImageTransfer': true});
    try {
      final cancelled = expectLater(
        dio.get('http://127.0.0.1:${server.port}/stall',
            options: options, cancelToken: token),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)),
      );
      final healthy =
          dio.get('http://127.0.0.1:${server.port}/ok', options: options);
      await both.future.timeout(const Duration(seconds: 2));
      token.cancel();
      await cancelled;
      expect((await healthy).data, 'ok');
    } finally {
      dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('reader header deadline closes the socket, not just its Future',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sawRequest = Completer<void>();
    final disconnected = Completer<void>();
    final peers = <Socket>[];
    server.listen((socket) {
      peers.add(socket);
      socket.listen((data) {
        if (!sawRequest.isCompleted) sawRequest.complete();
      }, onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
      });
    });
    try {
      final transport = ReaderImageTransport(
        headerTimeout: const Duration(milliseconds: 100),
      );
      final result = expectLater(
        transport.fetch('http://127.0.0.1:${server.port}/',
            proxy: 'DIRECT', phase: 'test'),
        throwsA(isA<TimeoutException>()),
      );
      await sawRequest.future.timeout(const Duration(seconds: 2));
      await result;
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    }
  });

  test('reader body inactivity deadline aborts a partial response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final disconnected = Completer<void>();
    final peers = <Socket>[];
    server.listen((socket) {
      peers.add(socket);
      bool sent = false;
      socket.listen((_) {
        if (sent) return;
        sent = true;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx');
      }, onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
      });
    });
    try {
      final transport = ReaderImageTransport(
        idleTimeout: const Duration(milliseconds: 60),
      );
      await expectLater(
        transport.fetch('http://127.0.0.1:${server.port}/',
            proxy: 'DIRECT', phase: 'test'),
        throwsA(isA<TimeoutException>()),
      );
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    }
  });

  for (final cancel in [false, true]) {
    test(
        'download ${cancel ? 'cancellation' : 'TLS timeout'} bounds the operation',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      final peers = <Socket>[];
      server.listen((socket) {
        peers.add(socket);
        socket.listen((_) {
          if (!received.isCompleted) received.complete();
        });
      });
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(milliseconds: cancel ? 5000 : 150),
        receiveTimeout: const Duration(seconds: 2),
      ))
        ..httpClientAdapter = HttpProxyAdapter(proxy: 'DIRECT');
      final token = CancelToken();
      try {
        final result = expectLater(
          dio.get<Uint8List>(
            'https://127.0.0.1:${server.port}/',
            cancelToken: token,
            options: Options(
              extra: {'feImageTransfer': true},
              responseType: ResponseType.bytes,
            ),
          ),
          throwsA(isA<DioException>().having(
              (e) => e.type,
              'type',
              cancel
                  ? DioExceptionType.cancel
                  : DioExceptionType.connectionTimeout)),
        );
        await received.future.timeout(const Duration(seconds: 2));
        if (cancel) token.cancel();
        await result;
        // Dart's TLS socket can outlive the cancelled ConnectionTask until
        // the handshake completes or the peer closes. Do not claim otherwise.
        // The app operation must finish and its retry budget remains bounded.
      } finally {
        dio.close(force: true);
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
      }
    });
  }
}

class _Settings extends GetxService implements EhSettingService {
  @override
  bool get nativeHttpClientAdapter => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
