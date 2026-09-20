import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/cache_controller.dart';
import 'package:eros_fe/common/controller/download/download_task_manager.dart';
import 'package:eros_fe/common/controller/download/image_download_processor.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/image_retry_policy.dart';
import 'package:eros_fe/store/db/entity/gallery_image_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

const _policy =
    ImageRetryPolicy(delays: [Duration.zero, Duration.zero, Duration.zero]);
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    Logger.level = Level.off;
    temp = await Directory.systemTemp.createTemp('handshake-recovery-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (_) async => temp.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    await temp.delete(recursive: true);
  });

  for (final scenario in [(1, 3), (2, 3), (3, 3), (1, 1)]) {
    test('page ${scenario.$1}/${scenario.$2} recovers by changing source',
        () async {
      final fixture = _Fixture(temp, scenario.$1, scenario.$2);
      final plan = fixture.plan;
      expect(plan.refreshLink, true); // Includes first, last and single pages.
      await fixture.run();
      expect(fixture.processor.transfers, 2);
      expect(fixture.processor.fetches, 2);
      expect(fixture.processor.sources, [null, 'fresh-source']);
      expect(fixture.stored[scenario.$1]!.status, TaskStatus.complete.value);
      expect(fixture.completions, 1);
      expect(
          await File(path.join(temp.path, '000${scenario.$1}.png'))
              .readAsBytes(),
          _png);
      expect(fixture.processor.getReDownloadCount(123, scenario.$1), 0);
    });
  }

  test('persistent TLS failure stops after four attempts without completion',
      () async {
    final fixture = _Fixture(temp, 1, 1)..processor.alwaysFail = true;
    await expectLater(fixture.run(), throwsA(isA<DioException>()));
    expect(fixture.processor.transfers, 4);
    expect(fixture.processor.sources.last, 'fresh-source');
    expect(fixture.completions, 0);
    expect(fixture.stored[1]!.status, TaskStatus.running.value);
    expect(await File(path.join(temp.path, '0001.png')).exists(), false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fixture.processor.transfers, 4); // No background retry monitor.
  });

  test('a deliberate later resume gets a fresh bounded retry budget', () async {
    final fixture = _Fixture(temp, 1, 1)..processor.alwaysFail = true;
    await expectLater(fixture.run(), throwsA(isA<DioException>()));
    fixture.processor.alwaysFail = false;
    await fixture.run();
    expect(fixture.processor.transfers, 6);
    expect(fixture.completions, 1);
  });

  test('retry after exhaustion skips completed rows and keeps their files',
      () async {
    final fixture = _Fixture(temp, 1, 3)..processor.alwaysFail = true;
    final completedRows = [fixture.stored[2], fixture.stored[3]];
    final completedFiles = [
      await File(path.join(temp.path, '0002.png')).writeAsBytes([..._png, 2]),
      await File(path.join(temp.path, '0003.png')).writeAsBytes([..._png, 3]),
    ];
    await expectLater(fixture.run(), throwsA(isA<DioException>()));
    expect(fixture.plan.ser, 1);
    fixture.processor.alwaysFail = false;
    await fixture.run();
    expect(fixture.stored[2], same(completedRows[0]));
    expect(fixture.stored[3], same(completedRows[1]));
    expect(await completedFiles[0].readAsBytes(), [..._png, 2]);
    expect(await completedFiles[1].readAsBytes(), [..._png, 3]);
    expect(fixture.state.pendingImageTasks(3, fixture.stored.values.toList()),
        isEmpty);
  });

  test('cache arriving after TLS failure wins before refreshing metadata',
      () async {
    final fixture = _Fixture(temp, 1, 1);
    fixture.processor.onFailure = () async {
      final image = fixture.state.downloadMap[123]!.single;
      final cache = File(path.join(temp.path, 'cacheimage', image.cacheKey));
      await cache.parent.create(recursive: true);
      await cache.writeAsBytes(_png);
    };
    await fixture.run();
    expect(fixture.processor.transfers, 1);
    expect(fixture.processor.fetches, 1);
    expect(fixture.completions, 1);
  });

  test('cancellation during backoff never starts another request', () async {
    final policy = _WaitingPolicy();
    final fixture = _Fixture(temp, 1, 1, policy: policy);
    final token = CancelToken();
    final expectation = expectLater(
        fixture.run(token: token),
        throwsA(
            isA<DioException>().having(CancelToken.isCancel, 'cancel', true)));
    await policy.waiting.future;
    token.cancel();
    await expectation;
    expect(fixture.processor.transfers, 1);
    expect(fixture.completions, 0);
  });

  test('quota/status and local persistence failures are not retried', () async {
    for (final error in <Object>[
      DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: RequestOptions(), statusCode: 429),
      ),
      const FileSystemException('synthetic write failure'),
    ]) {
      final fixture = _Fixture(temp, 1, 1)..processor.failure = error;
      await expectLater(fixture.run(), throwsA(same(error)));
      expect(fixture.processor.transfers, 1);
      expect(fixture.completions, 0);
    }
  });

  test('default policy backs off and is finite', () {
    const policy = ImageRetryPolicy();
    expect(policy.maxAttempts, 4);
    expect(policy.delays.map((d) => d.inSeconds), [1, 2, 4]);
    expect(policy.canRetry(const HandshakeException('fixture'), 3), true);
    expect(policy.canRetry(const HandshakeException('fixture'), 4), false);
    expect(ImageRetryPolicy.isTransient(const FileSystemException()), false);
  });
}

class _Fixture {
  _Fixture(this.directory, this.page, this.pageCount,
      {ImageRetryPolicy policy = _policy}) {
    stored.addEntries([
      for (int ser = 1; ser <= pageCount; ser++)
        MapEntry(
          ser,
          GalleryImageTask(
            gid: 123,
            token: '',
            ser: ser,
            href: 'https://example.test/s/key/123-$ser',
            imageUrl: 'https://failing.example.test/$ser.png',
            sourceId: 'stale-source',
            status: ser == page
                ? TaskStatus.running.value
                : TaskStatus.complete.value,
          ),
        ),
    ]);
    processor = _Processor(state, policy);
  }

  final Directory directory;
  final int page, pageCount;
  final state = DownloadState();
  final stored = <int, GalleryImageTask>{};
  late final _Processor processor;
  int completions = 0;
  ImageTaskPlan get plan =>
      state.pendingImageTasks(pageCount, stored.values.toList()).single;

  Future<void> run({CancelToken? token}) {
    state.restoreImageMetadata(123, stored.values.toList());
    final current = plan;
    return processor.downloadImageFlow(
      state.downloadMap[123]!.firstWhere((i) => i.ser == page),
      current.previousTask,
      123,
      directory.path,
      pageCount + 1,
      reDownload: current.refreshLink,
      cancelToken: token,
      putImageTaskCallback: (gid, image, filename, status) async {
        stored[page] = GalleryImageTask(
          gid: gid,
          token: '',
          ser: page,
          href: image.href,
          imageUrl: image.imageUrl,
          sourceId: image.sourceId,
          filePath: filename,
          status: status,
        );
      },
      onDownloadCompleteWithFileName: (_) => completions++,
    );
  }
}

class _Processor extends ImageDownloadProcessor {
  _Processor(DownloadState state, ImageRetryPolicy policy)
      : super(state, _Cache(), retryPolicy: policy);
  int transfers = 0, fetches = 0;
  final sources = <String?>[];
  bool alwaysFail = false;
  Object? failure;
  Future<void> Function()? onFailure;

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
    sources.add(sourceId);
    return image.copyWith(
      imageUrl:
          'https://${sourceId == null ? 'failing' : 'healthy'}.example.test/$itemSer.png'
              .oN,
      sourceId: 'fresh-source'.oN,
    );
  }

  @override
  Future<void> transferImage(
    String url,
    String Function(Headers) savePathBuilder, {
    CancelToken? cancelToken,
    ProgressCallback? progressCallback,
  }) async {
    transfers++;
    if (failure != null) throw failure!;
    if (alwaysFail || Uri.parse(url).host == 'failing.example.test') {
      await onFailure?.call();
      throw DioException(
        requestOptions: RequestOptions(path: url),
        error: const HandshakeException('WRONG_VERSION_NUMBER'),
      );
    }
    final output = savePathBuilder(Headers.fromMap({
      'content-disposition': ['attachment; filename="fixture.png"'],
    }));
    await File(output).writeAsBytes(_png);
    progressCallback?.call(_png.length, _png.length);
  }
}

class _WaitingPolicy extends ImageRetryPolicy {
  _WaitingPolicy() : super(delays: [const Duration(hours: 1)]);
  final waiting = Completer<void>();
  @override
  Future<void> wait(int failures, CancelToken? token) {
    waiting.complete();
    return super.wait(failures, token);
  }
}

class _Cache implements CacheController {
  @override
  Future<void> clearDioCache({required String path}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
