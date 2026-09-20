import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/index.dart';

// 下载状态检查相关常量
const int kPeriodSeconds = 1;
const int kMaxCount = 3;

class DownloadMonitor {
  DownloadMonitor(this.dState);
  final DownloadState dState;

  /// 初始化下载任务计时器
  void initDownloadStateChkTimer(int gid, {Function? onTimerCallback}) {
    // 每隔[kPeriodSeconds]时间， 执行一次
    dState.chkTimers[gid] = Timer.periodic(
      const Duration(seconds: kPeriodSeconds),
      (Timer timer) {
        if (onTimerCallback != null) {
          Function.apply(onTimerCallback, [gid, timer]);
          return;
        }

        // 此处为默认实现，当没有提供回调时使用
        final task = dState.galleryTaskMap[gid];
        if (task != null && task.fileCount == task.completCount) {
          cancelDownloadStateChkTimer(gid: gid);
          return;
        }

        if (dState.galleryTaskMap[gid]?.status == 2) {
          // 运行状态
          // Display progress only; per-page operations own retry decisions.
          updateDownloadSpeed(
            gid,
            maxCount: kMaxCount,
            periodSeconds: kPeriodSeconds,
          );
        }
      },
    );
  }

  /// 取消下载任务定时器
  void cancelDownloadStateChkTimer({int? gid}) {
    if (gid != null) {
      dState.downloadSpeeds.remove(gid);
      dState.noSpeed.remove(gid);
      dState.chkTimers[gid]?.cancel();
    } else {
      for (final Timer? timer in dState.chkTimers.values) {
        timer?.cancel();
      }
      dState.downloadSpeeds.clear();
      dState.noSpeed.clear();
    }
  }

  /// 计算并更新下载速度显示
  void updateDownloadSpeed(int gid, {int maxCount = 3, int periodSeconds = 1}) {
    // 计算当前总下载量
    final int totCurCount = dState.downloadCounts.entries
        .where((element) => element.key.startsWith('${gid}_'))
        .map((e) => e.value)
        .sum;

    // 记录历史数据
    dState.lastCounts.putIfAbsent(gid, () => [0]);
    dState.lastCounts[gid]?.add(totCurCount);
    final List<int> lastCounts = dState.lastCounts[gid] ?? [0];
    if (lastCounts.length > maxCount) {
      lastCounts.removeRange(0, lastCounts.length - maxCount);
    }

    // 计算用于显示的速度（使用较短时间窗口，更新及时）
    final List<int> lastCountsTopShow = lastCounts.reversed
        .toList()
        .sublist(0, min(lastCounts.length, maxCount));

    final speedShow = (max(totCurCount - lastCountsTopShow.reversed.first, 0) /
            (lastCountsTopShow.length * periodSeconds))
        .round();

    logger.t(
        'speedShow:${renderSize(speedShow)}\n${lastCountsTopShow.join(',')}');

    // 更新UI显示
    dState.downloadSpeeds[gid] = renderSize(speedShow);
  }
}
