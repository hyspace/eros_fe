import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/cache_controller.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:eros_fe/common/controller/download/download_task_manager.dart';
import 'package:eros_fe/common/controller/download/image_download_processor.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/api.dart';
import 'package:eros_fe/network/reader_image_cache.dart';
import 'package:eros_fe/network/reader_image_transport.dart';
import 'package:eros_fe/widget/image/reader_image_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

const _channel = MethodChannel('plugins.flutter.io/path_provider');
const _href = 'https://example.test/s/page/123-6';
GalleryImage fixture(
        {String xres = '', double? width = 1280, double? height = 8}) =>
    GalleryImage(
      ser: 6,
      href: _href,
      imageUrl: 'https://node.example.test/image.png$xres',
      originImageUrl: 'https://example.test/fullimg.php?page=6',
      imageWidth: width,
      imageHeight: height,
    );

Future<void> resolve(ReaderImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final done = Completer<void>();
  final listener = ImageStreamListener((info, _) {
    info.dispose();
    if (!done.isCompleted) {
      done.complete();
    }
  },
      onError: (Object error, StackTrace? stack) =>
          done.completeError(error, stack));
  stream.addListener(listener);
  try {
    await done.future;
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory cache;
  final bytes =
      Uint8List.fromList(image.encodePng(image.Image(width: 1280, height: 8)));
  setUp(() async {
    Logger.level = Level.off;
    temp = await Directory.systemTemp.createTemp('cache-representation-');
    cache = await Directory(path.join(temp.path, 'cacheimage')).create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => temp.path);
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    activeDownloadDiagnostics = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await temp.delete(recursive: true);
  });
  Future<void> legacy(String suffix, [List<int>? data]) =>
      File(path.join(cache.path, '${Uri.encodeComponent(_href)}_$suffix'))
          .writeAsBytes(data ?? bytes)
          .then((_) {});
  Future<Uint8List?> read(GalleryImage item) => readReaderImageCache(
        url: item.imageUrl!,
        cacheKey: item.cacheKey,
        spec: item.getCacheSpec(item.imageUrl!),
      );

  test(
      'same dimensions normalize xres and host changes, not original or resolution',
      () {
    final plain = fixture();
    final scaled = fixture(xres: '?xres=1280');
    expect(plain.cacheKey, scaled.cacheKey);
    expect(plain.cacheKey, isNot(fixture(width: 1600).cacheKey));
    expect(plain.cacheKey, isNot(fixture(height: 9).cacheKey));
    expect(plain.cacheKey, isNot(plain.getCacheKey(plain.originImageUrl!)));
    expect(fixture(width: null).cacheKey, endsWith('_'));
    expect(fixture(width: double.nan).cacheKey, endsWith('_'));
    expect(fixture(width: -1).cacheKey, endsWith('_'));
    expect(fixture(width: 1280.5).cacheKey, endsWith('_'));
  });

  for (final suffix in ['', '1280', '1600']) {
    test(
        'old suffix "$suffix" can be reused only after actual dimensions match',
        () async {
      await legacy(suffix);
      expect(await read(fixture()), bytes);
      expect(await read(fixture(xres: '?xres=1280')), bytes);
    });
  }
  test('a different height/width, page or original is never a resampled hit',
      () async {
    await legacy('');
    expect(await read(fixture(width: 1600)), isNull);
    expect(await read(fixture(height: 9)), isNull);
    expect(
        await read(
            fixture().copyWith(href: 'https://example.test/s/other/123-7'.oN)),
        isNull);
    await File(path.join(cache.path, '${Uri.encodeComponent(_href)}_'))
        .delete();
    await legacy('origin');
    expect(await read(fixture()), isNull);
  });
  test('corrupt alias is skipped and missing metadata never guesses 1280',
      () async {
    await legacy('', [1, 2, 3]);
    await legacy('1280');
    expect(await read(fixture()), bytes);
    expect(await read(fixture(width: null, height: null)), isNull);
  });
  test('exact ambiguous legacy key is dimension-checked as well', () async {
    await legacy('');
    final item = fixture(width: 1600);
    expect(
        await readReaderImageCache(
          url: item.imageUrl!,
          cacheKey: item.getCacheSpec(item.imageUrl!).legacyKey,
          spec: item.getCacheSpec(item.imageUrl!),
        ),
        isNull);
  });
  test('original requests never use resampled aliases', () async {
    await legacy('1280');
    final item = fixture();
    expect(
        await readReaderImageCache(
          url: item.originImageUrl!,
          cacheKey: item.getCacheKey(item.originImageUrl!),
          spec: item.getCacheSpec(item.originImageUrl!),
        ),
        isNull);
  });
  test('diagnostics report a legacy alias as cached without exposing its name',
      () async {
    await legacy('');
    final diagnostics =
        DownloadDiagnostics(File(path.join(temp.path, 'trace')));
    activeDownloadDiagnostics = diagnostics;
    await recordReaderCache(fixture(xres: '?xres=1280'), phase: 'reader');
    await diagnostics.flush();
    final text = await diagnostics.file.readAsString();
    final event = jsonDecode(text) as Map;
    expect(event['disk_cached'], true);
    expect(event['key_type'], 'reader_alias');
    expect(text, isNot(contains('https')));
    expect(text, isNot(contains(Uri.encodeComponent(_href))));
  });
  test('reader/preload use both legacy forms without networking', () async {
    final transport = _NoNetwork();
    for (final suffix in ['', '1280']) {
      await legacy(suffix);
      final item = fixture(xres: suffix.isEmpty ? '?xres=1280' : '');
      await resolve(ReaderImageProvider(
        item.imageUrl!,
        cacheKey: item.cacheKey,
        cacheSpec: item.getCacheSpec(item.imageUrl!),
        phase: suffix.isEmpty ? 'reader' : 'preload',
        transport: transport,
      ));
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await File(path.join(cache.path, '${Uri.encodeComponent(_href)}_$suffix'))
          .delete();
    }
    expect(transport.requests, 0);
  });
  test('new reader writes canonical cache reusable after URL format changes',
      () async {
    final transport = _BytesTransport(bytes);
    final first = fixture(xres: '?xres=1280');
    await resolve(ReaderImageProvider(
      first.imageUrl!,
      cacheKey: first.cacheKey,
      cacheSpec: first.getCacheSpec(first.imageUrl!),
      transport: transport,
    ));
    expect(await read(fixture()), bytes);
    final saved = await Api.saveImageFromExtendedCache(
      imageUrl: fixture().imageUrl!,
      cacheKey: fixture().cacheKey,
      cacheSpec: fixture().getCacheSpec(fixture().imageUrl!),
      parentPath: temp.path,
      fileNameWithoutExtension: '0006',
    );
    expect(await File(saved!).readAsBytes(), bytes);
    expect(transport.requests, 1);
  });
  for (final afterMetadata in [false, true]) {
    test(
        'download alias hit ${afterMetadata ? "after" : "before"} metadata skips transfer',
        () async {
      await legacy('');
      final item = fixture(xres: '?xres=1280');
      final state = DownloadState();
      final processor = _Processor(state, item);
      var completed = 0;
      await processor.downloadImageFlow(
        afterMetadata ? const GalleryImage(ser: 6, href: _href) : item,
        null,
        123,
        temp.path,
        42,
        putImageTaskCallback: (_, __, ___, status) async {
          if (status == TaskStatus.complete.value) {
            completed++;
          }
        },
      );
      expect(completed, 1);
      expect(processor.fetches, afterMetadata ? 1 : 0);
      expect(processor.transfers, 0);
    });
  }
}

class _NoNetwork extends ReaderImageTransport {
  int requests = 0;
  @override
  Future<Uint8List> fetch(
    String url, {
    required String proxy,
    required String phase,
    int? gid,
    int? page,
    void Function(int, int?)? onProgress,
    diagnostics,
  }) async {
    requests++;
    throw StateError('Unexpected network request');
  }
}

class _BytesTransport extends _NoNetwork {
  _BytesTransport(this.bytes);
  final Uint8List bytes;
  @override
  Future<Uint8List> fetch(
    String url, {
    required String proxy,
    required String phase,
    int? gid,
    int? page,
    void Function(int, int?)? onProgress,
    diagnostics,
  }) async {
    requests++;
    return bytes;
  }
}

class _Processor extends ImageDownloadProcessor {
  _Processor(DownloadState state, this.image)
      : super(state, _CacheController());
  final GalleryImage image;
  int fetches = 0;
  int transfers = 0;
  @override
  Future<GalleryImage> fetchImageInfo(
    String href, {
    required int itemSer,
    required GalleryImage image,
    required int gid,
    String? sourceId,
    CancelToken? cancelToken,
    String? showKey,
  }) async {
    fetches++;
    return this.image;
  }

  @override
  Future<void> transferImage(
    String url,
    String Function(Headers) savePathBuilder, {
    CancelToken? cancelToken,
    ProgressCallback? progressCallback,
  }) async {
    transfers++;
    throw StateError('Unexpected network transfer');
  }
}

class _CacheController implements CacheController {
  @override
  Future<void> clearDioCache({required String path}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
