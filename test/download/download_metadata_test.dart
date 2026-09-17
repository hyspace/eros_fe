import 'package:eros_fe/common/controller/download/download_task_manager.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/store/db/entity/gallery_image_task.dart';
import 'package:flutter_test/flutter_test.dart';

const _reader = GalleryImage(
  ser: 19,
  href: 'https://example.test/s/key/123-19',
  imageUrl: 'https://image.example.test/image.png?xres=1280',
  originImageUrl: 'https://example.test/fullimg.php?page=19',
  sourceId: 'source-key',
  showKey: 'show-key',
);

void main() {
  test('resume preserves reader metadata when no new snapshot is supplied', () {
    final state = DownloadState()
      ..restoreImageMetadata(123, [], readerImages: [_reader])
      ..restoreImageMetadata(123, []);
    final restored = state.downloadMap[123]!.single;
    expect(restored.imageUrl, _reader.imageUrl);
    expect(restored.originImageUrl, _reader.originImageUrl);
    expect(restored.sourceId, _reader.sourceId);
    expect(restored.showKey, _reader.showKey);
  });

  test('thumbnail refresh does not overwrite resolved image details', () {
    final state = DownloadState()
      ..rememberResolvedImages(123, [_reader])
      ..mergeImagePreviews(123, [
        GalleryImage(ser: 19, href: _reader.href, imageUrl: ''),
      ]);
    expect(state.downloadMap[123]!.single.imageUrl, _reader.imageUrl);
    expect(
        state.downloadMap[123]!.single.originImageUrl, _reader.originImageUrl);
  });

  test('a different page href does not inherit obsolete image data', () {
    final state = DownloadState()
      ..rememberResolvedImages(123, [_reader])
      ..mergeImagePreviews(123, [
        const GalleryImage(
            ser: 19, href: 'https://example.test/s/changed/123-19'),
      ]);
    expect(state.downloadMap[123]!.single.imageUrl, isNull);
    expect(state.downloadMap[123]!.single.originImageUrl, isNull);
  });

  test('empty preview fields do not erase known page and source information',
      () {
    final state = DownloadState()
      ..rememberResolvedImages(123, [_reader])
      ..mergeImagePreviews(123, [
        const GalleryImage(
            ser: 19, href: '', imageUrl: '', sourceId: '', showKey: ''),
      ]);
    final restored = state.downloadMap[123]!.single;
    expect(restored.href, _reader.href);
    expect(restored.imageUrl, _reader.imageUrl);
    expect(restored.sourceId, _reader.sourceId);
    expect(restored.showKey, _reader.showKey);
  });

  test('latest resolved metadata wins over an older persisted URL', () {
    final latest =
        _reader.copyWith(imageUrl: 'https://new.example.test/a.png'.oN);
    final state = DownloadState()..rememberResolvedImages(123, [latest]);
    state.restoreImageMetadata(123, [
      GalleryImageTask(
        gid: 123,
        token: '',
        ser: 19,
        href: _reader.href,
        imageUrl: _reader.imageUrl,
      ),
    ]);
    expect(state.downloadMap[123]!.single.imageUrl, latest.imageUrl);
  });

  test('restored metadata does not reset completed database rows', () {
    final complete = GalleryImageTask(
      gid: 123,
      token: '',
      ser: 19,
      href: _reader.href,
      imageUrl: _reader.imageUrl,
      status: TaskStatus.complete.value,
      filePath: '0019.png',
    );
    final state = DownloadState()
      ..restoreImageMetadata(123, [complete], readerImages: [_reader]);
    expect(state.missingImageTasks(123, [complete]), isEmpty);
    expect(complete.filePath, '0019.png');
    expect(complete.status, TaskStatus.complete.value);
  });

  test('only new preview pages create new pending database rows', () {
    final existing = GalleryImageTask(gid: 123, token: '', ser: 19);
    final state = DownloadState()
      ..restoreImageMetadata(123, [
        existing
      ], readerImages: [
        _reader,
        const GalleryImage(ser: 20, href: 'https://example.test/s/next/123-20'),
      ]);
    expect(
        state.missingImageTasks(123, [existing]).map((task) => task.ser), [20]);
  });

  test('completed later pages produce a link-refresh plan for page 19', () {
    final state = DownloadState();
    final stored = [
      for (int ser = 1; ser <= 34; ser++)
        GalleryImageTask(
          gid: 123,
          token: '',
          ser: ser,
          status:
              ser == 19 ? TaskStatus.running.value : TaskStatus.complete.value,
        ),
    ];
    final plans = state.pendingImageTasks(34, stored);
    expect(plans, hasLength(1));
    expect(plans.single.ser, 19);
    expect(plans.single.refreshLink, isTrue);
    expect(state.pendingImageTasks(34, []).every((plan) => !plan.refreshLink),
        isTrue);
  });
}
