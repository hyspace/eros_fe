import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/image_endpoint_recovery.dart';
import 'package:eros_fe/network/image_transfer_adapter.dart';
import 'package:eros_fe/network/preload_source_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

const _wrong = HandshakeException('fixture WRONG_VERSION_NUMBER');
final _uri = Uri.parse('https://node.group.hath.network/image?PRIVATE');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('classification is narrow, including wrapped OSError', () {
    expect(ImageEndpointRecovery.wrongVersion(_wrong), true);
    expect(
        ImageEndpointRecovery.wrongVersion(DioException(
            requestOptions: RequestOptions(),
            error: const HandshakeException(
                'failed', OSError('WRONG_VERSION_NUMBER')))),
        true);
    expect(
        ImageEndpointRecovery.wrongVersion(
            const HandshakeException('certificate_verify_failed')),
        false);
    expect(
        ImageEndpointRecovery.wrongVersion(
            const SocketException('WRONG_VERSION_NUMBER')),
        false);
    expect(
        ImageEndpointRecovery.wrongVersion(StateError('WRONG_VERSION_NUMBER')),
        false);
  });
  test('cooldown is exact endpoint/route, bounded, expires, and can be cleared',
      () {
    var now = DateTime(2026);
    final recovery = ImageEndpointRecovery(now: () => now, capacity: 2);
    recovery.failed(_uri, 'DIRECT');
    expect(
        recovery.shouldAvoid(_uri.replace(path: '/another'), 'DIRECT'), true);
    expect(
        recovery.shouldAvoid(
            _uri.replace(host: 'other.group.hath.network'), 'DIRECT'),
        false);
    expect(recovery.shouldAvoid(_uri.replace(port: 8443), 'DIRECT'), false);
    expect(recovery.shouldAvoid(_uri, 'PROXY private:123'), false);
    now = now.add(const Duration(seconds: 60));
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    for (final host in ['a.hath.network', 'b.hath.network', 'c.hath.network']) {
      recovery.failed(_uri.replace(host: host), 'DIRECT');
    }
    expect(recovery.shouldAvoid(_uri.replace(host: 'a.hath.network'), 'DIRECT'),
        false);
    recovery.clear();
    expect(recovery.shouldAvoid(_uri.replace(host: 'c.hath.network'), 'DIRECT'),
        false);
  });
  test('a fullimg redirect failure cannot quarantine the gallery/API origin',
      () {
    final recovery = ImageEndpointRecovery();
    final site = Uri.parse('https://exhentai.org/fullimg.php?PRIVATE');
    recovery.failed(site, 'DIRECT');
    expect(recovery.shouldAvoid(site, 'DIRECT'), false);
    expect(
        recovery.shouldAvoid(
            Uri.parse('https://exhentai.org/api.php'), 'DIRECT'),
        false);
  });

  Future<List<int>> run(ImageTransferAdapter adapter, {String? method}) async {
    final response = await adapter.fetch(
        RequestOptions(path: _uri.toString(), method: method ?? 'GET'),
        null,
        null);
    return response.stream.expand((b) => b).toList();
  }

  test('healthy endpoint uses only the normal transport and closes it',
      () async {
    final normal = _Normal();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: ImageEndpointRecovery(),
        normalAdapterFactory: () => normal);
    expect(await run(adapter), [1, 2]);
    expect(normal.calls, 1);
    expect(normal.closes, 1);
    adapter.close();
  });
  test('wrong version makes one attempt, preserves its cause and cools down',
      () async {
    final normal = _Normal()..failure = _wrong;
    final recovery = ImageEndpointRecovery();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: recovery,
        normalAdapterFactory: () => normal);
    await expectLater(run(adapter), throwsA(same(_wrong)));
    expect(normal.calls, 1);
    expect(normal.closes, 1);
    expect(recovery.needsNewSource(_wrong), true);
    await expectLater(run(adapter), throwsA(isA<ImageEndpointUnavailable>()));
    expect(normal.calls, 1);
    recovery.clear();
    normal.failure = null;
    expect(await run(adapter), [1, 2]);
    expect(normal.calls, 2);
    adapter.close();
  });
  test('disabling fast failover still never adds a fallback connection',
      () async {
    final normal = _Normal()..failure = _wrong;
    final recovery = ImageEndpointRecovery(fastFailover: false);
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: recovery,
        normalAdapterFactory: () => normal);
    for (int i = 0; i < 2; i++) {
      await expectLater(run(adapter), throwsA(same(_wrong)));
    }
    expect(normal.calls, 2);
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    expect(recovery.needsNewSource(_wrong), false);
    adapter.close();
  });
  test(
      'certificate errors do not enter wrong-version cooldown or change source',
      () async {
    const error = HandshakeException('CERTIFICATE_VERIFY_FAILED');
    final normal = _Normal()..failure = error;
    final recovery = ImageEndpointRecovery();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: recovery,
        normalAdapterFactory: () => normal);
    await expectLater(run(adapter), throwsA(same(error)));
    expect(normal.calls, 1);
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    expect(recovery.needsNewSource(error), false);
    adapter.close();
  });
  test('proxy requests retain their error without a direct fallback', () async {
    final normal = _Normal()..failure = _wrong;
    final recovery = ImageEndpointRecovery();
    final adapter = ImageTransferAdapter(
        proxy: 'PROXY private:123',
        skipCertificate: false,
        recovery: recovery,
        normalAdapterFactory: () => normal);
    await expectLater(run(adapter), throwsA(same(_wrong)));
    expect(normal.calls, 1);
    expect(recovery.shouldAvoid(_uri, 'PROXY private:123'), true);
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    adapter.close();
  });
  test(
      'range, custom Host, method and request bodies reach normal IO unchanged',
      () async {
    for (final options in [
      RequestOptions(path: _uri.toString(), headers: {'Range': 'bytes=10-20'}),
      RequestOptions(
          path: _uri.toString(), headers: {'Host': 'mapped.example.test'}),
      RequestOptions(path: _uri.toString(), method: 'POST', data: 'body'),
    ]) {
      final normal = _Normal();
      final stream = Stream.value(Uint8List.fromList([7, 8]));
      final adapter = ImageTransferAdapter(
          proxy: 'DIRECT',
          skipCertificate: false,
          recovery: ImageEndpointRecovery(),
          normalAdapterFactory: () => normal);
      final response = await adapter.fetch(options, stream, null);
      expect(await response.stream.expand((b) => b).toList(), [1, 2]);
      expect(normal.options, same(options));
      expect(normal.requestStream, same(stream));
      expect(normal.calls, 1);
      adapter.close();
    }
  });
  test('cancellation after normal failure does not quarantine the endpoint',
      () async {
    final cancel = Completer<void>();
    final normal = _Normal()
      ..failure = _wrong
      ..beforeFailure = () async {
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
      };
    final recovery = ImageEndpointRecovery();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: recovery,
        normalAdapterFactory: () => normal);
    await expectLater(
        adapter.fetch(
            RequestOptions(path: _uri.toString()), null, cancel.future),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)));
    expect(normal.calls, 1);
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    adapter.close();
  });
  test('closed adapter cannot start another connection', () async {
    final normal = _Normal();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        normalAdapterFactory: () => normal);
    adapter.close();
    await expectLater(run(adapter), throwsA(isA<StateError>()));
    expect(normal.calls, 0);
  });
  test(
      'preload changes source only once, and reruns the same cache-first loader',
      () async {
    const first = GalleryImage(
        ser: 1,
        href: 'https://example.test/s/1',
        imageUrl: 'https://bad.hath.network/1',
        sourceId: 'private-source');
    int loads = 0, sources = 0;
    final result = await preloadWithSourceRecovery(first, load: (item) async {
      loads++;
      if (loads == 1) {
        throw _wrong;
      }
    }, changeSource: (item) async {
      sources++;
      return item.copyWith(imageUrl: 'https://good.hath.network/1'.oN);
    });
    expect(loads, 2);
    expect(sources, 1);
    expect(result.imageUrl, contains('good'));
    loads = 0;
    await expectLater(
        preloadWithSourceRecovery(first,
            load: (_) async {
              loads++;
              throw _wrong;
            },
            changeSource: (item) async => item),
        throwsA(same(_wrong)));
    expect(loads, 2);
  });
}

class _Normal implements HttpClientAdapter {
  Object? failure;
  Future<void> Function()? beforeFailure;
  int calls = 0;
  int closes = 0;
  RequestOptions? options;
  Stream<Uint8List>? requestStream;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    this.options = options;
    this.requestStream = requestStream;
    if (failure != null) {
      await beforeFailure?.call();
      throw failure!;
    }
    return ResponseBody(Stream.value(Uint8List.fromList([1, 2])), 200);
  }

  @override
  void close({bool force = false}) {
    closes++;
  }
}
