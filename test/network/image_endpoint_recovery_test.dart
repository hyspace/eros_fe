import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/image_endpoint_recovery.dart';
import 'package:eros_fe/network/image_transfer_adapter.dart';
import 'package:eros_fe/network/native_sni_compatibility.dart';
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
  test('compatibility only allows HTTPS H@H without userinfo or explicit proxy',
      () {
    final recovery = ImageEndpointRecovery();
    expect(recovery.canUseCompatibility(_uri, 'DIRECT'), true);
    for (final uri in [
      _uri.replace(scheme: 'http'),
      _uri.replace(port: 8443),
      _uri.replace(userInfo: 'private'),
      _uri.replace(host: 'hath.network.evil.test'),
      Uri.parse('https://forums.e-hentai.org/'),
    ]) {
      expect(recovery.canUseCompatibility(uri, 'DIRECT'), false);
    }
    expect(recovery.canUseCompatibility(_uri, 'SOCKS5 private:8888'), false);
    expect(recovery.canUseCompatibility(_uri, 'PROXY private:8888'), false);
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

  test(
      'healthy endpoints never enter compatibility; wrong version gets one fallback',
      () async {
    final normal = _Normal();
    final compat = _Compat();
    final recovery = ImageEndpointRecovery();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: true,
        recovery: recovery,
        compatibility: compat,
        normalAdapterFactory: () => normal);
    expect(await run(adapter), [1, 2]);
    expect(compat.calls, 0);
    normal.failure = _wrong;
    expect(await run(adapter), [3, 4]);
    expect(compat.calls, 1);
    expect(recovery.shouldAvoid(_uri, 'DIRECT'), false);
    // Successful compatibility does not stick: a repaired server is used normally.
    normal.failure = null;
    expect(await run(adapter), [1, 2]);
    expect(compat.calls, 1);
    adapter.close();
  });
  test(
      'failed fallback preserves initial error and briefly avoids only that host',
      () async {
    final normal = _Normal()..failure = _wrong;
    final compat = _Compat()
      ..failure = StateError('strict verification failed');
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: true,
        recovery: ImageEndpointRecovery(),
        compatibility: compat,
        normalAdapterFactory: () => normal);
    await expectLater(run(adapter), throwsA(same(_wrong)));
    await expectLater(run(adapter), throwsA(isA<ImageEndpointUnavailable>()));
    expect(normal.calls, 1);
    expect(compat.calls, 1);
    adapter.close();
  });
  test(
      'both independent switches can disable the workaround without changing ordinary IO',
      () async {
    final normal = _Normal()..failure = _wrong;
    final compat = _Compat();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: true,
        recovery:
            ImageEndpointRecovery(fastFailover: false, sniCompatibility: false),
        compatibility: compat,
        normalAdapterFactory: () => normal);
    for (int i = 0; i < 2; i++) {
      await expectLater(run(adapter), throwsA(same(_wrong)));
    }
    expect(normal.calls, 2);
    expect(compat.calls, 0);
    adapter.close();
  });
  test('other errors, POSTs and proxies cannot enter the no-SNI path',
      () async {
    for (final scenario in [
      ('DIRECT', 'GET', const HandshakeException('certificate_verify_failed')),
      ('DIRECT', 'POST', _wrong),
      ('PROXY private:123', 'GET', _wrong),
    ]) {
      final normal = _Normal()..failure = scenario.$3;
      final compat = _Compat();
      final adapter = ImageTransferAdapter(
          proxy: scenario.$1,
          skipCertificate: true,
          recovery: ImageEndpointRecovery(),
          compatibility: compat,
          normalAdapterFactory: () => normal);
      await expectLater(
          run(adapter, method: scenario.$2), throwsA(same(scenario.$3)));
      expect(compat.calls, 0);
      adapter.close();
    }
  });
  test('range, custom Host and request bodies cannot be silently changed',
      () async {
    for (final options in [
      RequestOptions(path: _uri.toString(), headers: {'Range': 'bytes=10-20'}),
      RequestOptions(
          path: _uri.toString(), headers: {'Host': 'mapped.example.test'}),
      RequestOptions(path: _uri.toString(), data: 'body'),
    ]) {
      final normal = _Normal()..failure = _wrong;
      final compat = _Compat();
      final adapter = ImageTransferAdapter(
          proxy: 'DIRECT',
          skipCertificate: true,
          recovery: ImageEndpointRecovery(),
          compatibility: compat,
          normalAdapterFactory: () => normal);
      await expectLater(
          adapter.fetch(options, null, null), throwsA(same(_wrong)));
      expect(compat.calls, 0);
      adapter.close();
    }
  });
  test('either feature can remain enabled while the other is disabled',
      () async {
    for (final compatibilityOnly in [true, false]) {
      final normal = _Normal()..failure = _wrong;
      final compat = _Compat();
      final adapter = ImageTransferAdapter(
          proxy: 'DIRECT',
          skipCertificate: true,
          recovery: ImageEndpointRecovery(
              fastFailover: !compatibilityOnly,
              sniCompatibility: compatibilityOnly),
          compatibility: compat,
          normalAdapterFactory: () => normal);
      if (compatibilityOnly) {
        expect(await run(adapter), [3, 4]);
        expect(await run(adapter), [3, 4]);
        expect(compat.calls, 2);
      } else {
        await expectLater(run(adapter), throwsA(same(_wrong)));
        await expectLater(
            run(adapter), throwsA(isA<ImageEndpointUnavailable>()));
        expect(compat.calls, 0);
      }
      adapter.close();
    }
  });
  test('cancellation after normal failure must not start compatibility',
      () async {
    final cancel = Completer<void>();
    final normal = _Normal()
      ..failure = _wrong
      ..beforeFailure = () async {
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
      };
    final compat = _Compat();
    final adapter = ImageTransferAdapter(
        proxy: 'DIRECT',
        skipCertificate: false,
        recovery: ImageEndpointRecovery(),
        compatibility: compat,
        normalAdapterFactory: () => normal);
    await expectLater(
        adapter.fetch(
            RequestOptions(path: _uri.toString()), null, cancel.future),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)));
    expect(compat.calls, 0);
    adapter.close();
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
      if (loads == 1) throw _wrong;
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
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    if (failure != null) {
      await beforeFailure?.call();
      throw failure!;
    }
    return ResponseBody(Stream.value(Uint8List.fromList([1, 2])), 200);
  }

  @override
  void close({bool force = false}) {}
}

class _Compat implements SniCompatibilityTransport {
  int calls = 0;
  Object? failure;
  @override
  bool get supported => true;
  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Future<void>? cancelFuture) async {
    calls++;
    if (failure != null) throw failure!;
    return ResponseBody(Stream.value(Uint8List.fromList([3, 4])), 200);
  }

  @override
  void close() {}
}
