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
import 'package:eros_fe/store/db/entity/gallery_image_task.dart';
import 'package:executor/executor.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const _image = GalleryImage(
  ser: 1,
  href: 'https://example.test/s/abc/123-1',
  imageUrl: 'https://images.example.test/page.png?xres=1280',
  originImageUrl: 'https://example.test/fullimg.php?gid=123&page=1',
  showKey: 'reader-show-key',
);
const _safDirectory =
    'content://com.android.externalstorage.documents/tree/ABCD-1234%3ADownload'
    '/document/ABCD-1234%3ADownload%2Fgallery';
const _safChannel =
    MethodChannel('io.alexrintt.plugins/sharedstorage/documentfile');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAF'
  'gAI/ScLbtAAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late Directory cache;
  late Directory destination;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-cache-test-');
    cache = await Directory(path.join(temporary.path, 'cacheimage')).create();
    destination =
        await Directory(path.join(temporary.path, 'downloads')).create();
    messenger.setMockMethodCallHandler(_pathChannel, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return temporary.path;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_pathChannel, null);
    messenger.setMockMethodCallHandler(_safChannel, null);
    await temporary.delete(recursive: true);
  });

  Future<File> cacheImage({
    GalleryImage image = _image,
    String? url,
    bool legacy = false,
    List<int>? bytes,
  }) {
    final imageUrl = url ?? image.imageUrl!;
    final key = legacy ? keyToMd5(imageUrl) : image.getCacheKey(imageUrl);
    return File(path.join(cache.path, key)).writeAsBytes(bytes ?? _png);
  }

  Future<String?> save({
    GalleryImage image = _image,
    String? url,
    String? parentPath,
    CancelToken? cancelToken,
  }) {
    final imageUrl = url ?? image.imageUrl!;
    return Api.saveImageFromExtendedCache(
      imageUrl: imageUrl,
      cacheKey: image.getCacheKey(imageUrl),
      parentPath: parentPath ?? destination.path,
      fileNameWithoutExtension: '0001',
      cancelToken: cancelToken,
    );
  }

  group('reader cache export', () {
    test('reuses the actual reader key and preserves the cache bytes',
        () async {
      final cached = await cacheImage();
      expect(await getCachedImageFile(_image.imageUrl!), isNull);

      final saved = await save();

      expect(saved, path.join(destination.path, '0001.png'));
      expect(await File(saved!).readAsBytes(), _png);
      expect(await cached.readAsBytes(), _png);
    });

    test('same page and resolution reuse cache after the image URL changes',
        () async {
      await cacheImage();
      final saved = await save(
        url: 'https://another-source.example.test/new.png?xres=1280',
      );
      expect(await File(saved!).readAsBytes(), _png);
    });

    test('falls back to old URL-keyed caches', () async {
      await cacheImage(legacy: true);
      final saved = await save();
      expect(await File(saved!).readAsBytes(), _png);
    });

    test('legacy callers without a custom key still work', () async {
      await cacheImage(legacy: true);
      final saved = await Api.saveImageFromExtendedCache(
        imageUrl: _image.imageUrl!,
        parentPath: destination.path,
        fileNameWithoutExtension: '0001',
      );
      expect(await File(saved!).readAsBytes(), _png);
    });

    test('prefers the reader key over an older URL-keyed image', () async {
      await cacheImage();
      await cacheImage(legacy: true, bytes: [..._png, 42]);
      final saved = await save();
      expect(await File(saved!).readAsBytes(), _png);
    });

    test('does not confuse different pages or resolutions', () async {
      await cacheImage();
      expect(await save(url: '${_image.imageUrl!}0'), isNull);
      expect(
        await save(
          image: _image.copyWith(
            href: 'https://example.test/s/def/123-2'.oN,
          ),
          url: 'https://images.example.test/page2.png?xres=1280',
        ),
        isNull,
      );
      expect(destination.listSync(), isEmpty);
    });

    test('does not export resampled cache as an original', () async {
      await cacheImage();
      expect(await save(url: _image.originImageUrl), isNull);
      expect(destination.listSync(), isEmpty);
    });

    test('original cache uses a separate key', () async {
      await cacheImage(url: _image.originImageUrl, bytes: [..._png, 1]);
      expect(await save(), isNull);
      final saved = await save(url: _image.originImageUrl);
      expect(await File(saved!).readAsBytes(), [..._png, 1]);
    });

    test('returns a miss when the cache was cleared', () async {
      final cached = await cacheImage();
      await cached.delete();
      expect(await save(), isNull);
    });

    test('empty and non-image cache files are misses', () async {
      await cacheImage(bytes: []);
      expect(await save(), isNull);
      await cacheImage(bytes: utf8.encode('<html>error</html>'));
      expect(await save(), isNull);
      expect(destination.listSync(), isEmpty);
    });

    test('an invalid custom cache can fall back to a valid legacy cache',
        () async {
      await cacheImage(bytes: []);
      await cacheImage(legacy: true);
      final saved = await save();
      expect(await File(saved!).readAsBytes(), _png);
    });

    test('detects WebP from its 12-byte signature', () async {
      final webp = [
        ...ascii.encode('RIFF'),
        20,
        0,
        0,
        0,
        ...ascii.encode('WEBP')
      ];
      await cacheImage(bytes: webp);
      final saved = await save();
      expect(saved, path.join(destination.path, '0001.webp'));
      expect(await File(saved!).readAsBytes(), webp);
    });

    test('writes cache bytes through the existing SAF API', () async {
      await cacheImage();
      messenger.setMockMethodCallHandler(_safChannel, (call) async {
        expect(call.method, 'createFile');
        final arguments = call.arguments as Map;
        expect(arguments['directoryUri'], _safDirectory);
        expect(arguments['content'], _png);
        expect(arguments['mimeType'], 'image/png');
        expect(arguments['displayName'], '0001.png');
        return {'uri': '$_safDirectory%2F0001.png', 'name': '0001.png'};
      });
      expect(await save(parentPath: _safDirectory), '0001.png');
    });

    test('uses the actual filename returned by a SAF provider', () async {
      await cacheImage();
      messenger.setMockMethodCallHandler(_safChannel, (call) async {
        return {'uri': '$_safDirectory%2F0001.png', 'name': '0001 (1).png'};
      });
      expect(await save(parentPath: _safDirectory), '0001 (1).png');
    });

    test('a failed SAF write is an error, not a cache miss or success',
        () async {
      await cacheImage();
      messenger.setMockMethodCallHandler(_safChannel, (_) async => null);
      await expectLater(
        save(parentPath: _safDirectory),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a filesystem write error is not treated as a cache miss', () async {
      await cacheImage();
      await expectLater(
        save(parentPath: path.join(destination.path, 'missing')),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('cancellation prevents exporting an image', () async {
      await cacheImage();
      final token = CancelToken()..cancel();
      await expectLater(
        save(cancelToken: token),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)),
      );
      expect(destination.listSync(), isEmpty);
    });
  });

  group('ordinary download flow', () {
    late _SpyProcessor processor;
    late DownloadState state;
    late List<String> completions;
    late List<GalleryImage> savedImages;
    late List<int?> savedStatuses;

    setUp(() {
      state = DownloadState();
      processor = _SpyProcessor(state);
      completions = [];
      savedImages = [];
      savedStatuses = [];
    });

    Future<void> download({
      GalleryImage image = _image,
      GalleryImageTask? imageTask,
      bool original = false,
      bool retry = false,
      String? parentPath,
      CancelToken? token,
      Future<void> Function()? beforeComplete,
    }) {
      return processor.downloadImageFlow(
        image,
        imageTask,
        123,
        parentPath ?? destination.path,
        3,
        downloadOrigImage: original,
        reDownload: retry,
        cancelToken: token,
        putImageTaskCallback: (gid, savedImage, fileName, status) async {
          expect(gid, 123);
          savedImages.add(savedImage);
          savedStatuses.add(status);
        },
        onDownloadCompleteWithFileName: (name) async {
          await beforeComplete?.call();
          completions.add(name);
        },
      );
    }

    test('a reader cache hit bypasses both metadata fetch and download',
        () async {
      await cacheImage();
      await download();
      expect(processor.fetchCount, 0);
      expect(processor.downloads, isEmpty);
      expect(completions, ['0001.png']);
      expect(savedImages, [_image]);
      expect(savedStatuses, [TaskStatus.complete.value]);
      expect(state.showKeyMap[123], 'reader-show-key');
      expect(
          state.downloadCounts, isEmpty); // Local copy is not network traffic.
    });

    test('cache reuse does not require showKey', () async {
      await cacheImage();
      await download(image: _image.copyWith(showKey: null.oN));
      expect(processor.fetchCount, 0);
      expect(processor.downloads, isEmpty);
      expect(completions, ['0001.png']);
    });

    test('a cache hit keeps the existing task filename', () async {
      await cacheImage();
      await download(
        imageTask: GalleryImageTask(
          gid: 123,
          ser: 1,
          token: '',
          filePath: 'page-001.png',
        ),
      );
      expect(completions, ['page-001.png']);
    });

    test('only uncached pages reach the download path', () async {
      await cacheImage();
      await download();
      final second = _image.copyWith(
        ser: 2,
        href: 'https://example.test/s/def/123-2'.oN,
        imageUrl: 'https://images.example.test/page2.png?xres=1280'.oN,
      );
      processor.fetchedImage = second;
      await download(image: second);
      expect(processor.fetchCount, 1);
      expect(processor.downloads.map((d) => d.url), [second.imageUrl]);
      expect(completions, ['0001.png', '0002.png']);
    });

    test('post-fetch cache lookup also receives the reader key', () async {
      await cacheImage();
      processor.useRealDownload = true;
      await download(
        image: _image.copyWith(imageUrl: null.oN, originImageUrl: null.oN),
      );
      expect(processor.fetchCount, 1);
      expect(processor.downloads.single.cacheKey, _image.cacheKey);
      expect(completions, ['0001.png']);
      expect(await File(path.join(destination.path, '0001.png')).readAsBytes(),
          _png);
    });

    test('original download never accepts a resampled reader cache', () async {
      await cacheImage();
      await download(original: true);
      expect(processor.fetchCount, 1);
      expect(processor.downloads.single.url, _image.originImageUrl);
      expect(processor.downloads.single.cacheKey,
          _image.getCacheKey(_image.originImageUrl!));
    });

    test('unknown original URL is resolved before choosing a version',
        () async {
      await cacheImage();
      await download(
        original: true,
        image: _image.copyWith(originImageUrl: null.oN),
      );
      expect(processor.fetchCount, 1);
      expect(processor.downloads.single.url, _image.originImageUrl);
    });

    test('known original reader cache bypasses metadata requests', () async {
      await cacheImage(url: _image.originImageUrl);
      await download(original: true);
      expect(processor.fetchCount, 0);
      expect(processor.downloads, isEmpty);
      expect(completions, ['0001.png']);
    });

    test('resuming an original task does not use its stored resampled URL',
        () async {
      await download(
        original: true,
        imageTask: GalleryImageTask(
          gid: 123,
          ser: 1,
          token: '',
          imageUrl: _image.imageUrl,
        ),
      );
      expect(processor.fetchCount, 1);
      expect(processor.downloads.single.url, _image.originImageUrl);
    });

    test('automatic link refresh still uses the reader cache first', () async {
      await cacheImage();
      await download(retry: true);
      expect(processor.fetchCount, 0);
      expect(processor.downloads, isEmpty);
      expect(completions, ['0001.png']);
    });

    test('an expired URL refresh carries the matching cache key', () async {
      processor.failFirstDownload = true;
      await download();
      expect(processor.fetchCount, 2);
      expect(processor.downloads, hasLength(2));
      expect(processor.downloads.last.cacheKey, _image.cacheKey);
      expect(completions, ['0001.png']);
      expect(savedStatuses.last, TaskStatus.complete.value);
    });

    test('automatic 403 recovery keeps the cache enabled', () async {
      processor.failFirstDownload = true;
      await download(retry: true);
      expect(processor.downloads, hasLength(2));
      expect(processor.downloads.every((item) => item.useCache), isTrue);
    });

    test('cached completion waits for the image task to be persisted',
        () async {
      await cacheImage();
      final writeStarted = Completer<void>();
      final writeFinished = Completer<void>();
      final pending = processor.downloadImageFlow(
        _image,
        null,
        123,
        destination.path,
        3,
        putImageTaskCallback: (gid, image, name, status) async {
          writeStarted.complete();
          await writeFinished.future;
        },
        onDownloadCompleteWithFileName: completions.add,
      );
      await writeStarted.future;
      expect(completions, isEmpty);
      writeFinished.complete();
      await pending;
      expect(completions, ['0001.png']);
    });

    test('completion waits for SAF persistence and the async callback',
        () async {
      await cacheImage();
      final writeStarted = Completer<void>();
      final writeFinished = Completer<void>();
      final callbackStarted = Completer<void>();
      final callbackFinished = Completer<void>();
      messenger.setMockMethodCallHandler(_safChannel, (_) async {
        writeStarted.complete();
        await writeFinished.future;
        return {'uri': '$_safDirectory%2F0001.png', 'name': '0001.png'};
      });
      bool finished = false;
      final pending = download(
        parentPath: _safDirectory,
        beforeComplete: () async {
          callbackStarted.complete();
          await callbackFinished.future;
        },
      ).then((_) => finished = true);
      await writeStarted.future;
      expect(savedImages, isEmpty);
      expect(completions, isEmpty);
      expect(finished, isFalse);
      writeFinished.complete();
      await callbackStarted.future;
      expect(savedStatuses, [TaskStatus.complete.value]);
      expect(finished, isFalse);
      callbackFinished.complete();
      await pending;
      expect(finished, isTrue);
      expect(completions, ['0001.png']);
    });

    test('SAF failure does not trigger a new download or mark completion',
        () async {
      await cacheImage();
      messenger.setMockMethodCallHandler(_safChannel, (_) async => null);
      await expectLater(download(parentPath: _safDirectory),
          throwsA(isA<FileSystemException>()));
      expect(processor.fetchCount, 0);
      expect(processor.downloads, isEmpty);
      expect(savedImages, isEmpty);
      expect(completions, isEmpty);
    });

    test('cancellation during SAF export does not mark the task complete',
        () async {
      await cacheImage();
      final token = CancelToken();
      messenger.setMockMethodCallHandler(_safChannel, (_) async {
        token.cancel();
        return {'uri': '$_safDirectory%2F0001.png'};
      });
      await expectLater(
        download(parentPath: _safDirectory, token: token),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)),
      );
      expect(savedImages, isEmpty);
      expect(completions, isEmpty);
    });

    test('downloadToPath waits for the cache completion callback', () async {
      await cacheImage();
      final started = Completer<void>();
      final finish = Completer<void>();
      bool returned = false;
      final realProcessor = ImageDownloadProcessor(state, _CacheController());
      final pending = realProcessor.downloadToPath(
        _image.imageUrl!,
        destination.path,
        '0001',
        cacheKey: _image.cacheKey,
        onDownloadCompleteWithFileName: (_) async {
          started.complete();
          await finish.future;
        },
      ).then((_) => returned = true);
      await started.future;
      expect(returned, isFalse);
      finish.complete();
      await pending;
      expect(returned, isTrue);
    });
  });

  group('retry pipeline with real cache files and task planning', () {
    test('34-page task reuses page 19 when cache arrives before gap retry',
        () async {
      final state = DownloadState();
      final diagnostics =
          DownloadDiagnostics(File(path.join(temporary.path, 'trace.log')));
      addTearDown(diagnostics.flush);
      final catalog = {
        for (int ser = 1; ser <= 34; ser++)
          ser: _image.copyWith(
            ser: ser,
            href: 'https://example.test/s/key$ser/123-$ser'.oN,
            imageUrl:
                'https://images.example.test/$ser.png?xres=1280&key=PRIVATE'.oN,
            originImageUrl: 'https://example.test/fullimg.php?page=$ser'.oN,
            sourceId: 'source-$ser'.oN,
          ),
      };
      for (final image in catalog.values.where((image) => image.ser != 19)) {
        await cacheImage(image: image);
      }
      state.restoreImageMetadata(123, [],
          readerImages: catalog.values.toList());
      final persisted = {
        for (final task in state.missingImageTasks(123, [])) task.ser: task,
      };
      final processor = _PipelineProcessor(state, catalog, diagnostics)
        ..failuresRemaining = 1;
      final failures = <Object>[];
      final completions = <int>[];

      Future<void> runPlans(List<ImageTaskPlan> plans) async {
        final executor = Executor(concurrency: 4);
        await Future.wait(plans.map((plan) {
          return executor
              .scheduleTask<void>(() => processor.downloadImageFlow(
                    state.downloadMap[123]!
                        .firstWhere((image) => image.ser == plan.ser),
                    plan.previousTask,
                    123,
                    destination.path,
                    35,
                    reDownload: plan.refreshLink,
                    putImageTaskCallback: (gid, image, name, status) async {
                      persisted[image.ser] = GalleryImageTask(
                        gid: gid,
                        ser: image.ser,
                        token: '',
                        href: image.href,
                        imageUrl: image.imageUrl,
                        sourceId: image.sourceId,
                        filePath: name,
                        status: status,
                      );
                    },
                    onDownloadCompleteWithFileName: (_) =>
                        completions.add(plan.ser),
                  ))
              .catchError((Object error) {
            failures.add(error);
          });
        }));
        await executor.close();
      }

      // Initial attempt: 33 disk-cache hits and one real pipeline TLS failure.
      await runPlans(state.pendingImageTasks(34, []));
      expect(completions, hasLength(33));
      expect(failures, hasLength(1));
      expect(processor.transfers, 1);
      expect(processor.fetches, 1);
      expect(persisted[19]?.sourceId, 'resolved-source-19');
      expect(persisted[19]?.status, TaskStatus.running.value);

      // Resume the way the download controller does, with no reader argument.
      final stored = persisted.values.toList();
      state.restoreImageMetadata(123, stored);
      expect(state.missingImageTasks(123, stored), isEmpty);
      final retry = state.pendingImageTasks(34, stored);
      expect(retry, hasLength(1));
      expect(retry.single.ser, 19);
      expect(retry.single.refreshLink, isTrue);
      await cacheImage(image: catalog[19]!);
      await runPlans(retry);

      expect(completions, hasLength(34));
      expect(completions.toSet(), hasLength(34));
      expect(processor.transfers, 1); // Never tries the failing endpoint again.
      expect(processor.fetches, 1); // No redundant page/API lookup on retry.
      expect(
          persisted.values
              .every((task) => task.status == TaskStatus.complete.value),
          isTrue);
      expect(await File(path.join(destination.path, '0019.png')).readAsBytes(),
          _png);
      await diagnostics.flush();
      final events = (await diagnostics.file.readAsLines())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(events.where((event) => event['event'] == 'network_start'),
          hasLength(1));
      final error =
          events.singleWhere((event) => event['event'] == 'network_error');
      expect(error['page'], 19);
      expect(error['tls_error'], 'wrong_version_number');
      expect(events.where((event) => event['event'] == 'cache_saved'),
          hasLength(34));
      expect(await diagnostics.file.readAsString(), isNot(contains('PRIVATE')));
    });

    test('a cold resume can find cache using persisted metadata', () async {
      await cacheImage();
      final stored = [
        GalleryImageTask(
          gid: 123,
          ser: 1,
          token: '',
          href: _image.href,
          imageUrl: _image.imageUrl,
          status: TaskStatus.running.value,
        ),
      ];
      final state = DownloadState()..restoreImageMetadata(123, stored);
      final processor = _PipelineProcessor(state, {1: _image}, null);
      final plan = state.pendingImageTasks(1, stored).single;
      await processor.downloadImageFlow(
        state.downloadMap[123]!.single,
        plan.previousTask,
        123,
        destination.path,
        2,
        reDownload: plan.refreshLink,
      );
      expect(processor.fetches, 0);
      expect(processor.transfers, 0);
      expect(await File(path.join(destination.path, '0001.png')).readAsBytes(),
          _png);
    });

    test('cancelled metadata response cannot overwrite a resumed attempt',
        () async {
      final state = DownloadState();
      final processor = _PipelineProcessor(state, {1: _image}, null)
        ..cancelAfterFetch = true;
      final persisted = <GalleryImage>[];
      final token = CancelToken();
      await expectLater(
        processor.downloadImageFlow(
          _image,
          null,
          123,
          destination.path,
          2,
          cancelToken: token,
          putImageTaskCallback: (gid, image, name, status) async {
            persisted.add(image);
          },
        ),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)),
      );
      expect(processor.transfers, 0);
      expect(persisted, isEmpty);
      expect(state.downloadMap[123], isNull);
    });

    test('reader diagnostic confirms the actual key exists on disk', () async {
      await cacheImage();
      final diagnostics =
          DownloadDiagnostics(File(path.join(temporary.path, 'reader.log')));
      activeDownloadDiagnostics = diagnostics;
      try {
        await recordReaderCache(_image, phase: 'reader');
        await diagnostics.flush();
        final event = jsonDecode(await diagnostics.file.readAsString()) as Map;
        expect(event['event'], 'reader_ready');
        expect(event['gid'], 123);
        expect(event['page'], 1);
        expect(event['key_hash'], keyToMd5(_image.cacheKey));
        expect(event['disk_cached'], isTrue);
        expect(event.toString(), isNot(contains(_image.href!)));
      } finally {
        activeDownloadDiagnostics = null;
      }
    });

    test('first cache miss remains a real network transfer, with diagnostics',
        () async {
      final state = DownloadState();
      final diagnostics =
          DownloadDiagnostics(File(path.join(temporary.path, 'miss.log')));
      final processor = _PipelineProcessor(state, {1: _image}, diagnostics);
      await processor.downloadImageFlow(
        _image,
        null,
        123,
        destination.path,
        2,
      );
      expect(processor.transfers, 1);
      expect(await File(path.join(destination.path, '0001.png')).readAsBytes(),
          _png);
      await diagnostics.flush();
      final events = (await diagnostics.file.readAsLines())
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(events.where((event) => event['event'] == 'cache_miss'),
          hasLength(4)); // Reader + legacy key, before and after metadata.
      final network =
          events.singleWhere((event) => event['event'] == 'network_complete');
      expect(network['bytes'], _png.length);
      expect(events.last['event'], 'page_complete');
    });
  });
}

// The actual cache export code is exercised above. Only remote metadata and
// network transfers are replaced here, so tests never contact the gallery site.
class _SpyProcessor extends ImageDownloadProcessor {
  _SpyProcessor(DownloadState state) : super(state, _CacheController());

  int fetchCount = 0;
  GalleryImage fetchedImage = _image;
  bool useRealDownload = false;
  bool failFirstDownload = false;
  final downloads = <({String url, String? cacheKey, bool useCache})>[];

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
    fetchCount++;
    return fetchedImage;
  }

  @override
  Future<void> downloadToPath(
    String url,
    String parentPath,
    String fileNameWithoutExtension, {
    String? cacheKey,
    bool useCache = true,
    int? gid,
    int? ser,
    String cachePhase = 'after_metadata',
    CancelToken? cancelToken,
    FutureOr<void> Function(String)? onDownloadCompleteWithFileName,
    ProgressCallback? progressCallback,
  }) async {
    downloads.add((url: url, cacheKey: cacheKey, useCache: useCache));
    if (failFirstDownload && downloads.length == 1) {
      final options = RequestOptions(path: url);
      throw DioException(
        requestOptions: options,
        response: Response<void>(requestOptions: options, statusCode: 403),
        type: DioExceptionType.badResponse,
      );
    }
    if (useRealDownload) {
      await super.downloadToPath(
        url,
        parentPath,
        fileNameWithoutExtension,
        cacheKey: cacheKey,
        useCache: useCache,
        gid: gid,
        ser: ser,
        cachePhase: cachePhase,
        cancelToken: cancelToken,
        onDownloadCompleteWithFileName: onDownloadCompleteWithFileName,
        progressCallback: progressCallback,
      );
    } else {
      await onDownloadCompleteWithFileName
          ?.call('$fileNameWithoutExtension.png');
    }
  }
}

class _PipelineProcessor extends ImageDownloadProcessor {
  _PipelineProcessor(
      DownloadState state, this.catalog, DownloadDiagnostics? diagnostics)
      : super(state, _CacheController(), diagnostics: diagnostics);

  final Map<int, GalleryImage> catalog;
  int failuresRemaining = 0;
  int fetches = 0;
  int transfers = 0;
  bool cancelAfterFetch = false;

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
    if (cancelAfterFetch) {
      cancelToken?.cancel();
    }
    return catalog[itemSer]!.copyWith(sourceId: 'resolved-source-$itemSer'.oN);
  }

  @override
  Future<void> transferImage(
    String url,
    String Function(Headers) savePathBuilder, {
    CancelToken? cancelToken,
    ProgressCallback? progressCallback,
  }) async {
    transfers++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw DioException(
        requestOptions: RequestOptions(path: url),
        error: const HandshakeException(
            'Handshake error: WRONG_VERSION_NUMBER(tls_record.cc:127)'),
      );
    }
    final output = savePathBuilder(Headers.fromMap({
      'content-disposition': ['attachment; filename="fixture.png"'],
    }));
    await File(output).writeAsBytes(_png);
    progressCallback?.call(_png.length, _png.length);
  }
}

class _CacheController implements CacheController {
  @override
  Future<void> clearDioCache({required String path}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
