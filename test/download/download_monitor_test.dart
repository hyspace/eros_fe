import 'package:eros_fe/common/controller/download/download_monitor.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('zero speed only updates display, never schedules a retry', () {
    final state = DownloadState();
    final monitor = DownloadMonitor(state);
    for (int complete = 1; complete <= 100; complete++) {
      state.curComplete[123] = complete;
      monitor.updateDownloadSpeed(123);
    }

    expect(state.downloadCounts, isEmpty);
    expect(state.noSpeed, isEmpty);
    expect(state.cancelTokenMap, isEmpty);
    expect(state.reDownloadCounts, isEmpty);
    expect(state.lastCounts[123], hasLength(3));
  });

  test('speed history is bounded for long-running downloads', () {
    final state = DownloadState();
    final monitor = DownloadMonitor(state);
    for (int i = 0; i < 1000; i++) {
      state.downloadCounts['123_1'] = i * 1024;
      monitor.updateDownloadSpeed(123);
    }

    expect(state.lastCounts[123], hasLength(3));
    expect(state.downloadSpeeds[123], isNotEmpty);
  });
}
