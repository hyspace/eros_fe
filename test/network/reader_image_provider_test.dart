import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/network/api.dart';
import 'package:eros_fe/network/image_retry_policy.dart';
import 'package:eros_fe/network/reader_image_transport.dart';
import 'package:eros_fe/widget/image/reader_image_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _key = 'https%3A%2F%2Fexample.test%2Fs%2Fkey%2F123-1_1280';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

Future<void> _resolve(ReaderImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final done = Completer<ImageInfo>();
  final listener = ImageStreamListener(
    (info, _) => done.complete(info),
    onError: (Object error, StackTrace? stack) =>
        done.completeError(error, stack),
  );
  stream.addListener(listener);
  try {
    final info = await done.future;
    expect(info.image.width, 1);
    info.dispose();
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Transport transport;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('reader-provider-');
    transport = _Transport();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (_) async => temp.path);
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    activeDownloadDiagnostics = null;
    await temp.delete(recursive: true);
  });

  ReaderImageProvider provider(
          {String url = 'https://image.example.test/a.png'}) =>
      ReaderImageProvider(
        url,
        cacheKey: _key,
        transport: transport,
        proxy: 'DIRECT',
        retryPolicy:
            const ImageRetryPolicy(delays: [Duration.zero, Duration.zero]),
      );

  test('new reader bytes remain reusable by the existing download cache code',
      () async {
    await _resolve(provider());
    expect(transport.requests, 1);
    final cached = File(path.join(temp.path, 'cacheimage', _key));
    expect(await cached.readAsBytes(), _png);
    final destination =
        await Directory(path.join(temp.path, 'downloads')).create();
    final saved = await Api.saveImageFromExtendedCache(
      imageUrl: 'https://different-node.example.test/b.png',
      cacheKey: _key,
      parentPath: destination.path,
      fileNameWithoutExtension: '0001',
    );
    expect(await File(saved!).readAsBytes(), _png);
    expect(transport.requests, 1);
    expect(
        (await cached.parent.list().toList()).whereType<Directory>(), isEmpty);
  });

  test('old reader cache works after an image URL changes without a request',
      () async {
    final cached = File(path.join(temp.path, 'cacheimage', _key));
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(_png);
    await _resolve(provider(url: 'https://new-node.example.test/a.png'));
    expect(transport.requests, 0);
  });

  test('a corrupt cache entry is replaced, not treated as a completed image',
      () async {
    final cached = File(path.join(temp.path, 'cacheimage', _key));
    await cached.parent.create(recursive: true);
    await cached.writeAsString('not an image');
    await _resolve(provider());
    expect(transport.requests, 1);
    expect(await cached.readAsBytes(), _png);
  });

  test('reader preserves TLS error and stops after its finite retry budget',
      () async {
    transport.error = const HandshakeException('WRONG_VERSION_NUMBER');
    await expectLater(_resolve(provider()), throwsA(same(transport.error)));
    expect(transport.requests, 3);
    expect(
        await File(path.join(temp.path, 'cacheimage', _key)).exists(), false);
  });

  test('reader and preload share their in-memory key', () {
    const a = ReaderImageProvider('https://example.test/a',
        cacheKey: _key, phase: 'reader', page: 1);
    const b = ReaderImageProvider('https://example.test/a',
        cacheKey: _key, phase: 'preload', page: 1);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('reader source changes cannot multiply into the old 18-attempt budget',
      () {
    const provider =
        ReaderImageProvider('https://example.test/a', cacheKey: _key);
    expect(provider.retryPolicy.maxAttempts, 3);
    expect(kReaderSourceRetries, 1);
    expect(provider.retryPolicy.maxAttempts * (kReaderSourceRetries + 1), 6);
  });
}

class _Transport extends ReaderImageTransport {
  int requests = 0;
  Object? error;

  @override
  Future<Uint8List> fetch(
    String url, {
    required String proxy,
    required String phase,
    int? gid,
    int? page,
    void Function(int, int?)? onProgress,
    DownloadDiagnostics? diagnostics,
  }) async {
    requests++;
    if (error != null) throw error!;
    onProgress?.call(_png.length, _png.length);
    return _png;
  }
}
