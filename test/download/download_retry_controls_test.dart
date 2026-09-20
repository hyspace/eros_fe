import 'package:eros_fe/common/controller/download_controller.dart';
import 'package:eros_fe/common/controller/download_state.dart';
import 'package:eros_fe/common/service/ehsetting_service.dart';
import 'package:eros_fe/common/service/theme_service.dart';
import 'package:eros_fe/const/theme_colors.dart';
import 'package:eros_fe/generated/l10n.dart';
import 'package:eros_fe/pages/item/download_gallery_item.dart';
import 'package:eros_fe/pages/tab/controller/download_view_controller.dart';
import 'package:eros_fe/store/db/entity/gallery_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';

const _gid = 123;
const _vibration = MethodChannel('vibration');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Downloads downloads;
  late _ViewController view;

  setUp(() {
    Logger.level = Level.off;
    Get.testMode = true;
    downloads = _Downloads();
    Get.put<DownloadController>(downloads);
    Get.put<EhSettingService>(_Settings());
    Get.put<ThemeService>(_Theme());
    view = _ViewController();
    Get.put<DownloadViewController>(view);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vibration, (_) async => false);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_vibration, null);
    Get.reset();
  });

  Future<GalleryTask> showTask(
    WidgetTester tester,
    TaskStatus status, {
    String? error,
    Locale locale = const Locale('en'),
  }) async {
    final task = GalleryTask(
      gid: _gid,
      token: '',
      title: 'Download fixture',
      dirPath: null,
      fileCount: 26,
      completCount: status == TaskStatus.complete ? 26 : 25,
      status: status.value,
    );
    downloads.dState.galleryTaskMap[_gid] = task;
    await tester.pumpWidget(GetMaterialApp(
      locale: locale,
      supportedLocales: L10n.delegate.supportedLocales,
      localizationsDelegates: const [
        L10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: DownloadGalleryItem(
          galleryTask: task,
          taskIndex: 0,
          errInfo: error,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return task;
  }

  for (final status in [
    TaskStatus.paused,
    TaskStatus.failed,
    TaskStatus.canceled,
  ]) {
    testWidgets(
        '${status.value}: retry resumes gallery, never archive or reset',
        (tester) async {
      final task =
          await showTask(tester, status, error: 'Page 1: HandshakeException');
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('25/26'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resume-gallery-123')));
      await tester.pump();
      expect(downloads.resumes, [_gid]);
      expect(view.archiveRetries, isEmpty);
      expect(view.fullRestarts, isEmpty);
      expect(downloads.dState.galleryTaskMap[_gid], same(task));
      expect(task.completCount, 25);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('paused task without in-memory error still has Continue',
      (tester) async {
    // Also represents restoring a paused row after restarting the app.
    await showTask(tester, TaskStatus.paused);
    expect(find.text('Continue'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resume-gallery-123')));
    await tester.pump();
    expect(downloads.resumes, [_gid]);
    expect(view.fullRestarts, isEmpty);
  });

  testWidgets('long error text cannot hide the retry control on narrow screens',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await showTask(tester, TaskStatus.paused,
        error: 'Page 1: ${'HandshakeException ' * 30}');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('resume-gallery-123')));
    await tester.pump();
    expect(downloads.resumes, [_gid]);
  });

  testWidgets('menu distinguishes retry unfinished pages from redownload all',
      (tester) async {
    final task = await showTask(tester, TaskStatus.failed);
    view.onLongPress(0, task: task);
    await tester.pumpAndSettle();
    expect(find.text('Retry unfinished pages'), findsOneWidget);
    expect(find.text('Redownload all pages'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-unfinished-gallery')));
    await tester.pumpAndSettle();
    expect(downloads.resumes, [_gid]);
    expect(view.archiveRetries, isEmpty);
    expect(view.fullRestarts, isEmpty);
  });

  testWidgets(
      'Chinese retry labels clearly identify the non-destructive action',
      (tester) async {
    final task = await showTask(tester, TaskStatus.paused,
        error: 'Page 1: HandshakeException', locale: const Locale('zh', 'CN'));
    expect(find.text('重试'), findsOneWidget);
    view.onLongPress(0, task: task);
    await tester.pumpAndSettle();
    expect(find.text('重试未完成页'), findsOneWidget);
    expect(find.text('全部重新下载'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-unfinished-gallery')));
    await tester.pumpAndSettle();
    expect(downloads.resumes, [_gid]);
    expect(view.fullRestarts, isEmpty);
  });

  testWidgets('completed tasks do not offer a retry button', (tester) async {
    await showTask(tester, TaskStatus.complete);
    expect(find.byKey(const ValueKey('resume-gallery-123')), findsNothing);
    expect(downloads.resumes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _Downloads extends GetxController implements DownloadController {
  @override
  final dState = DownloadState();
  final resumes = <int>[];
  @override
  Future<void> galleryTaskResume(int gid) async => resumes.add(gid);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ViewController extends DownloadViewController {
  final archiveRetries = <int>[];
  final fullRestarts = <int?>[];
  @override
  // This UI fixture intentionally avoids Hive and archive-plugin startup.
  // ignore: must_call_super
  void onInit() {}
  @override
  void onReady() {}
  @override
  Future<void> retryArchiverDownload(int index) async =>
      archiveRetries.add(index);
  @override
  void restartGalleryDownload(int? gid) => fullRestarts.add(gid);
}

class _Settings extends GetxService implements EhSettingService {
  @override
  bool get isPureDarkTheme => false;
  @override
  RxBool vibrate = false.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Theme extends GetxService implements ThemeService {
  @override
  ThemesModeEnum get themeModel => ThemesModeEnum.lightMode;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
