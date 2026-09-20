import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eros_fe/network/native_sni_compatibility.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeSniCompatibility transport;
  late List<MethodCall> calls;
  int read = 0;
  RequestOptions options({Duration? timeout}) => RequestOptions(
          path: 'https://image.hath.network/PRIVATE?PRIVATE',
          connectTimeout: timeout,
          headers: {
            'Cookie': 'PRIVATE',
            'Authorization': 'PRIVATE',
            'User-Agent': 'test'
          });
  setUp(() {
    transport = NativeSniCompatibility();
    calls = [];
    read = 0;
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'start')
        return {
          'status': 200,
          'headers': {
            'content-type': ['image/png']
          }
        };
      if (call.method == 'read')
        return ++read < 3 ? Uint8List.fromList([read]) : null;
      return null;
    });
  });
  tearDown(() async {
    transport.close();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel, null);
  });
  test('streaming honors backpressure, filters secrets and releases after EOF',
      () async {
    final body = await transport.fetch(options(), null);
    expect(calls.map((c) => c.method), ['start']);
    expect((calls.first.arguments as Map)['headers'], {'User-Agent': 'test'});
    expect(await body.stream.expand((b) => b).toList(), [1, 2]);
    expect(calls.map((c) => c.method),
        ['start', 'read', 'read', 'read', 'cancel']);
  });
  test(
      'cancel during pending headers closes native request and never exposes response',
      () async {
    final response = Completer<Map>();
    final cancel = Completer<void>();
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'start') return response.future;
      return null;
    });
    final pending = transport.fetch(options(), cancel.future);
    final expected = expectLater(
        pending,
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)));
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    await Future<void>.delayed(Duration.zero);
    response.complete({'status': 200, 'headers': <String, dynamic>{}});
    await expected;
    expect(calls.where((c) => c.method == 'cancel').length, 1);
  });
  test('header timeout closes the native call', () async {
    final response = Completer<Map>();
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'start') return response.future;
      return null;
    });
    await expectLater(
        transport.fetch(
            options(timeout: const Duration(milliseconds: 20)), null),
        throwsA(isA<TimeoutException>()));
    expect(calls.last.method, 'cancel');
    response.complete({'status': 200, 'headers': <String, dynamic>{}});
  });
  test('native redirects never silently change host or downgrade TLS',
      () async {
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'start')
        return {
          'status': 302,
          'headers': {
            'location': ['http://evil.test/']
          }
        };
      return null;
    });
    await expectLater(
        transport.fetch(options(), null), throwsA(isA<HttpException>()));
    expect(calls.map((c) => c.method), ['start', 'cancel']);
  });
  test(
      'a streaming native failure releases resources without inventing success',
      () async {
    messenger.setMockMethodCallHandler(NativeSniCompatibility.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'start')
        return {'status': 200, 'headers': <String, dynamic>{}};
      if (call.method == 'read')
        throw PlatformException(code: 'transport_failed');
      return null;
    });
    final body = await transport.fetch(options(), null);
    await expectLater(body.stream.toList(), throwsA(isA<HttpException>()));
    expect(calls.last.method, 'cancel');
  });
}
