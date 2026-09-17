import 'dart:async';

import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/download/download_task_manager.dart'
    show TaskStatus;
import 'package:eros_fe/component/quene_task/quene_task.dart';
import 'package:eros_fe/models/base/eh_models.dart';
import 'package:eros_fe/store/db/entity/gallery_image_task.dart';
import 'package:eros_fe/store/db/entity/gallery_task.dart';
import 'package:executor/executor.dart';
import 'package:get/get.dart';

/// 轮询周期间隔 单位秒
const int kPeriodSeconds = 1;

/// 速度统计周期
const int kMaxCount = 4;

/// 速度统计周期
const int kCheckMaxCount = 10;

// 无速度多少个周期后重试
const int kRetryThresholdTime = 10;

// 达到此次数后才换源下载
const int kMaxReDownloadRetries = 3;

class DownloadState {
  DownloadState();
  final RxMap<int, GalleryTask> galleryTaskMap = <int, GalleryTask>{}.obs;

  List<GalleryTask> get galleryTasks => galleryTaskMap.values.toList()
    ..sort((b, a) => (a.addTime ?? 0).compareTo(b.addTime ?? 0));

  final downloadSpeeds = <int, String>{};

  final errInfoMap = <int, String>{};

  late Executor executor;

  QueueTask queueTask = QueueTask();
  final Map<int, TaskCancelToken> taskCancelTokens = {};

  final Map<int, List<GalleryImage>> downloadMap = <int, List<GalleryImage>>{};
  final Map<int, CancelToken> cancelTokenMap = <int, CancelToken>{};
  final showKeyMap = <int, String>{};
  final showKeyCompleteMap = <int, Completer>{};

  final Map<int, Timer?> chkTimers = {};
  final Map<int, int> preComplete = {};
  final Map<int, int> curComplete = {};

  final Map<String, int> downloadCounts = {};
  final Map<int, List<int>> lastCounts = {};

  final Map<int, int> noSpeed = {};

  // 重试计数器：key: "gid_ser", value: 重试次数
  final Map<String, int> reDownloadCounts = {};

  // 画廊任务额外信息 - 新增
  final Map<int, Map<String, dynamic>> galleryTaskExtraInfo = {};

  String? _preferKnown(String? value, String? fallback) =>
      (value?.isNotEmpty ?? false) ? value : fallback;

  /// Refreshing a thumbnail list must not erase already-resolved reader data.
  void mergeImagePreviews(int gid, Iterable<GalleryImage> images) {
    final known = {
      for (final image in downloadMap[gid] ?? <GalleryImage>[]) image.ser: image
    };
    for (final image in images) {
      final old = known[image.ser];
      final samePage = old != null &&
          ((image.href?.isEmpty ?? true) ||
              (old.href?.isEmpty ?? true) ||
              image.href == old.href);
      known[image.ser] = !samePage
          ? image
          : image.copyWith(
              href: _preferKnown(image.href, old.href).oN,
              imageUrl: (image.imageUrl?.isNotEmpty ?? false
                      ? image.imageUrl
                      : old.imageUrl)
                  .oN,
              originImageUrl: (image.originImageUrl?.isNotEmpty ?? false
                      ? image.originImageUrl
                      : old.originImageUrl)
                  .oN,
              sourceId: _preferKnown(image.sourceId, old.sourceId).oN,
              showKey: _preferKnown(image.showKey, old.showKey).oN,
              filename: _preferKnown(image.filename, old.filename).oN,
              imageWidth: (image.imageWidth ?? old.imageWidth).oN,
              imageHeight: (image.imageHeight ?? old.imageHeight).oN,
            );
    }
    downloadMap[gid] = known.values.toList();
  }

  void rememberResolvedImages(int gid, List<GalleryImage> images) {
    final known = {
      for (final image in downloadMap[gid] ?? <GalleryImage>[]) image.ser: image
    };
    for (final image in images) {
      known[image.ser] = image;
    }
    downloadMap[gid] = known.values.toList();
  }

  /// A resume keeps rich in-memory metadata; persisted URLs cover cold starts.
  void restoreImageMetadata(
    int gid,
    List<GalleryImageTask> stored, {
    List<GalleryImage>? readerImages,
  }) {
    final remembered = downloadMap[gid]?.toList() ?? <GalleryImage>[];
    downloadMap[gid] = [];
    mergeImagePreviews(gid, readerImages ?? []);
    mergeImagePreviews(
        gid,
        stored.map((task) => GalleryImage(
              ser: task.ser,
              href: task.href,
              imageUrl: task.imageUrl,
              sourceId: task.sourceId,
              token: task.token,
            )));
    mergeImagePreviews(gid, remembered);
  }

  /// Never overwrite completed rows with a reader/preview snapshot on resume.
  List<GalleryImageTask> missingImageTasks(
    int gid,
    List<GalleryImageTask> existing,
  ) {
    final existingSeries = existing.map((task) => task.ser).toSet();
    return [
      for (final image in downloadMap[gid] ?? <GalleryImage>[])
        if (!existingSeries.contains(image.ser))
          GalleryImageTask(
            gid: gid,
            token: image.token ?? '',
            ser: image.ser,
            href: image.href,
            imageUrl: image.imageUrl,
            sourceId: image.sourceId,
          ),
    ];
  }

  /// The existing gap-retry heuristic refreshes links, not image cache policy.
  List<ImageTaskPlan> pendingImageTasks(
    int fileCount,
    List<GalleryImageTask> existing,
  ) {
    final bySer = {for (final task in existing) task.ser: task};
    final maxComplete = existing
        .where((task) => task.status == TaskStatus.complete.value)
        .fold<int>(0, (value, task) => task.ser > value ? task.ser : value);
    return [
      for (int ser = 1; ser <= fileCount; ser++)
        if (bySer[ser]?.status != TaskStatus.complete.value)
          ImageTaskPlan(
            ser: ser,
            previousTask: bySer[ser],
            refreshLink: ser > 1 && ser < maxComplete + 2,
          ),
    ];
  }
}

class ImageTaskPlan {
  const ImageTaskPlan({
    required this.ser,
    required this.previousTask,
    required this.refreshLink,
  });

  final int ser;
  final GalleryImageTask? previousTask;
  final bool refreshLink;
}
