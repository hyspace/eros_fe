import 'package:eros_fe/common/controller/download/download_monitor.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cache-only page progress prevents false network-stall retries', () {
    final state = DownloadState();
    final monitor = DownloadMonitor(state);
    int retries = 0;

    for (int complete = 1; complete <= 20; complete++) {
      state.curComplete[123] = complete;
      monitor.checkDownloadStall(
        123,
        onRetryNeededCallback: (_) => retries++,
      );
    }

    expect(state.downloadCounts, isEmpty);
    expect(state.noSpeed[123], 0);
    expect(retries, 0);
  });

  test('a task with neither network nor page progress still retries', () {
    final state = DownloadState();
    final monitor = DownloadMonitor(state);
    int retries = 0;

    state.curComplete[123] = 1;
    monitor.checkDownloadStall(123);
    for (int i = 0; i < 5; i++) {
      monitor.checkDownloadStall(
        123,
        onRetryNeededCallback: (_) => retries++,
      );
    }

    expect(retries, 1);
  });
}
