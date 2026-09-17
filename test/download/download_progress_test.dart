import 'package:eros_fe/common/controller/cache_controller.dart';
import 'package:eros_fe/common/controller/download/download_task_manager.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/store/db/entity/gallery_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.put<CacheController>(_CacheController());
  });
  tearDown(Get.reset);

  test('progress updates do not launch unordered background database writes',
      () async {
    final state = DownloadState();
    state.galleryTaskMap[123] = GalleryTask(
      gid: 123,
      token: 'token',
      title: 'Fixture',
      dirPath: null,
      fileCount: 2,
      status: TaskStatus.running.value,
    );
    final manager = DownloadTaskManager(state);
    final task = manager.galleryTaskUpdate(
      123,
      countComplete: 1,
      coverImg: '0001.png',
    );

    expect(task?.completCount, 1);
    expect(task?.coverImage, '0001.png');
    expect(task?.status, TaskStatus.running.value);
    expect(state.curComplete[123], 1);
    // No Isar instance is initialized: the caller is responsible for the single,
    // awaited progress/final-state write, not a fire-and-forget isolate here.
    await Future<void>.delayed(Duration.zero);
  });
}

class _CacheController extends GetxController
    with StateMixin<String>
    implements CacheController {
  @override
  Future<void> clearDioCache({required String path}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
