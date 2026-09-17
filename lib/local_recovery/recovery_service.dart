import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:eros_fe/common/controller/download_controller.dart';
import 'package:eros_fe/common/global.dart';
import 'package:eros_fe/const/const.dart';
import 'package:eros_fe/extension.dart';
import 'package:eros_fe/models/index.dart';
import 'package:eros_fe/pages/tab/controller/download_view_controller.dart';
import 'package:eros_fe/store/db/entity/gallery_image_task.dart';
import 'package:eros_fe/store/db/entity/gallery_task.dart';
import 'package:eros_fe/store/db/entity/view_history.dart';
import 'package:eros_fe/store/hive/hive.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as path;
import 'package:shared_storage/shared_storage.dart' as ss;

import 'recovery_flags.dart';

typedef RecoveryProgress = void Function(String message);

class RecoveryService {
  static bool _busy = false;
  static const _columns = [
    ss.DocumentFileColumn.id,
    ss.DocumentFileColumn.displayName,
    ss.DocumentFileColumn.mimeType,
    ss.DocumentFileColumn.size,
  ];

  void _guard() {
    if (!localRecoveryEnabled || !Platform.isAndroid) {
      throw StateError('恢复功能仅在 Android 本地构建中启用');
    }
    if (localRecoveryTest &&
        Global.packageInfo.packageName != 'com.honjow.fehviewer.safrestore') {
      throw StateError('测试包身份校验失败');
    }
  }

  String get stagingPath =>
      path.join(Global.extStorePath, 'recovery-import.json');
  String get reportPath =>
      path.join(Global.extStorePath, 'recovery-db-report.json');

  String _treeId(Uri uri) {
    final s = uri.pathSegments;
    if (uri.scheme != 'content' ||
        uri.authority != 'com.android.externalstorage.documents' ||
        s.length != 2 ||
        s.first != 'tree' ||
        !s[1].contains(':')) {
      throw const FormatException('请选择有效的下载目录树，而不是单个文件');
    }
    return s[1];
  }

  bool _safeName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains('\u0000');

  Future<Map<String, dynamic>?> chooseInput() async {
    _guard();
    final files = await ss.openDocument();
    if (files == null || files.isEmpty) return null;
    final bytes = await ss.getDocumentContent(files.first);
    if (bytes == null) throw StateError('无法读取恢复文件');
    return decodeInput(utf8.decode(bytes));
  }

  Future<Map<String, dynamic>> stagedInput() async {
    _guard();
    if (!localRecoveryTest) throw StateError('ADB 暂存入口仅用于独立测试包');
    final file = File(stagingPath);
    if (!await file.exists()) throw StateError('尚未放入恢复暂存文件');
    if (await file.length() > 80 * 1024 * 1024) {
      throw StateError('恢复文件超过安全大小限制');
    }
    return decodeInput(await file.readAsString());
  }

  Map<String, dynamic> decodeInput(String text) {
    if (text.length > 80 * 1024 * 1024) {
      throw const FormatException('恢复文件过大');
    }
    final value = jsonDecode(text);
    if (value is! Map ||
        !['eros-fe-local-recovery-bundle', 'eros-fe-local-checkpoint']
            .contains(value['format']) ||
        value['schemaVersion'] != 1) {
      throw const FormatException('请选择下载恢复 JSON，不是原版 profile 配置备份');
    }
    final result = Map<String, dynamic>.from(value);
    final entries = result['preferredDownloadTasks'];
    if (entries is! List || entries.length > 10000) {
      throw const FormatException('无效的下载任务列表');
    }
    _treeId(Uri.parse((result['downloadRoot'] as Map)['treeUri'] as String));
    return result;
  }

  Future<Uri?> selectRoot(Map<String, dynamic> bundle) async {
    final expected =
        Uri.parse((bundle['downloadRoot'] as Map)['treeUri'] as String);
    final grants = await ss.persistedUriPermissions() ?? [];
    for (final grant in grants) {
      if (grant.uri == expected && grant.isReadPermission) return expected;
    }
    final selected = await ss.openDocumentTree(initialUri: expected);
    if (selected == null) return null;
    if (_treeId(selected) != _treeId(expected)) {
      throw StateError('选中的目录不是恢复文件记录的下载目录，请重新选择');
    }
    return selected;
  }

  List<Map<String, dynamic>> _entries(Map<String, dynamic> bundle) {
    final entries = (bundle['preferredDownloadTasks'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    // Keep the real directory GID, but never invent its token or total pages.
    // This remains paused and is explicitly identified as local-files-only.
    for (final raw in bundle['unresolvedDirectories'] as List? ?? []) {
      final e = Map<String, dynamic>.from(raw as Map);
      final gid = e['gid'];
      if (gid is! int || gid <= 0) throw StateError('本地目录缺少真实 GID');
      final files = e['observedFiles'] as List;
      final bySer = <int, Map>{};
      for (final rawFile in files) {
        final f = rawFile as Map;
        final m = RegExp(r'^(\d+)\.(?:jpe?g|webp|png|gif|avif)$',
                caseSensitive: false)
            .firstMatch(f['name'] as String);
        if (m != null && (f['bytes'] as num) > 0) {
          bySer.putIfAbsent(int.parse(m[1]!), () => f);
        }
      }
      final keys = bySer.keys.toList()..sort();
      if (keys.isEmpty || keys.first != 1 || keys.last != keys.length) {
        throw StateError('本地未知目录的页码不连续，需要人工核对');
      }
      final directory = e['relativeDirectory'] as String;
      entries.add({
        'relativeDirectory': directory,
        'galleryTask': {
          'gid': gid,
          'token': '',
          'title': directory.replaceFirst(RegExp(r'^\d+\s*-\s*'), ''),
          'fileCount': keys.length,
          'status': 6,
          'dirPath': '',
          'jsonString': jsonEncode({
            'feLocalRecovery': {
              'expectedPageCountKnown': false,
              'missingPages': 0,
              'source': 'files-only'
            }
          }),
        },
        'imageTasks': [
          for (final ser in keys)
            {
              'gid': gid,
              'ser': ser,
              'token': '',
              'filePath': bySer[ser]!['name'],
              'status': 3,
            }
        ],
      });
    }
    return entries;
  }

  Future<Map<String, dynamic>> importBundle(
    Map<String, dynamic> bundle,
    Uri root,
    RecoveryProgress progress, {
    bool importSettings = true,
  }) async {
    _guard();
    if (_busy) throw StateError('另一个恢复操作尚未结束');
    _busy = true;
    try {
      final expected =
          Uri.parse((bundle['downloadRoot'] as Map)['treeUri'] as String);
      if (_treeId(root) != _treeId(expected)) {
        throw StateError('恢复目录不匹配');
      }
      final db = isarHelper.isar;
      final existingTasks = await db.galleryTasks.where().findAll();
      if (existingTasks.any((e) => e.status == 1 || e.status == 2)) {
        throw StateError('请先暂停本应用的下载，避免恢复过程中发生写入冲突');
      }
      progress('读取目录与检查恢复文件…');
      final rootFiles = await ss.listFiles(root, columns: _columns).toList();
      final directories = {
        for (final file in rootFiles)
          if (file.isDirectory == true && file.name != null) file.name!: file,
      };
      final existing = {for (final task in existingTasks) task.gid: task};
      final entries = _entries(bundle);
      final seen = <int>{};
      final seenDirectories = <String>{};
      final tasks = <GalleryTask>[];
      final images = <GalleryImageTask>[];
      final skipped = <int>[];
      var index = 0;
      for (final entry in entries) {
        final name = entry['relativeDirectory'] as String;
        if (!_safeName(name) || !seenDirectories.add(name)) {
          throw StateError('恢复目录名称不安全或重复');
        }
        final original = GalleryTask.fromJson(
            Map<String, dynamic>.from(entry['galleryTask'] as Map));
        if (original.gid <= 0 ||
            !seen.add(original.gid) ||
            original.fileCount <= 0 ||
            original.fileCount > 100000) {
          throw StateError('GID 重复或页数无效');
        }
        final nameGid = RegExp(r'^(\d+)\s*-').firstMatch(name);
        if (nameGid != null && int.parse(nameGid[1]!) != original.gid) {
          throw StateError('目录 GID 与恢复记录不一致');
        }
        final note = recoveryNote(original.jsonString);
        final countKnown = note?['expectedPageCountKnown'] != false;
        if (original.token.isEmpty && countKnown) {
          throw StateError('漫画身份信息缺失：${original.gid}');
        }
        final previous = existing[original.gid];
        // An older snapshot is not allowed to truncate/replace newer tasks.
        if (previous != null &&
            (previous.fileCount > original.fileCount ||
                (previous.token.isNotEmpty &&
                    original.token.isNotEmpty &&
                    previous.token != original.token))) {
          skipped.add(original.gid);
          continue;
        }
        final directory = directories[name];
        if (directory == null) throw StateError('恢复目录已不存在：GID ${original.gid}');
        progress('检查 ${++index}/${entries.length}：GID ${original.gid}');
        final files =
            await ss.listFiles(directory.uri, columns: _columns).toList();
        final available = {
          for (final f in files)
            if (f.isFile == true && f.name != null && (f.size ?? 0) > 0)
              f.name!: f,
        };
        final records = (entry['imageTasks'] as List)
            .map((e) =>
                GalleryImageTask.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (records.length != original.fileCount) {
          throw StateError('图片记录数与页数不一致：${original.gid}');
        }
        final oldImages = previous == null
            ? <GalleryImageTask>[]
            : await db.galleryImageTasks
                .filter()
                .gidEqualTo(original.gid)
                .findAll();
        final oldBySer = {for (final image in oldImages) image.ser: image};
        final serials = <int>{};
        final rebuilt = <GalleryImageTask>[];
        for (final record in records) {
          if (record.gid != original.gid ||
              record.ser < 1 ||
              record.ser > original.fileCount ||
              !serials.add(record.ser)) {
            throw StateError('图片主键无效：${original.gid}');
          }
          String? fileName = record.filePath;
          if (fileName != null && !_safeName(fileName)) {
            throw StateError('不安全的图片文件名');
          }
          if (!available.containsKey(fileName)) {
            final oldName = oldBySer[record.ser]?.filePath;
            fileName = oldName != null && available.containsKey(oldName)
                ? oldName
                : null;
          }
          rebuilt.add(GalleryImageTask(
            gid: record.gid,
            ser: record.ser,
            token: record.token,
            href: record.href,
            sourceId: record.sourceId,
            imageUrl: '',
            filePath: fileName,
            status: fileName == null ? 6 : 3,
          ));
        }
        rebuilt.sort((a, b) => a.ser.compareTo(b.ser));
        final present = rebuilt.where((e) => e.filePath != null).length;
        final marker = <String, dynamic>{
          'expectedPageCountKnown': countKnown,
          'missingPages': original.fileCount - present,
          'source': bundle['format'],
        };
        final first = rebuilt.where((e) => e.filePath != null).firstOrNull;
        tasks.add(original.copyWith(
          dirPath: directory.uri.toString(),
          completCount: present,
          status: countKnown && present == original.fileCount ? 3 : 6,
          coverImage: available.containsKey(original.coverImage)
              ? original.coverImage
              : first?.filePath,
          jsonString: jsonEncode({
            'feLocalRecovery': marker,
            if (original.jsonString != null && note == null)
              'previousOpaqueJson': original.jsonString,
          }),
        ));
        images.addAll(rebuilt);
      }
      // Validate optional metadata completely before any transaction.
      final importedProfile =
          Profile.fromJson(Map<String, dynamic>.from(bundle['profile'] as Map));
      final histories = (bundle['readHistory'] as List? ?? [])
          .map((e) => ViewHistory.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final caches = (bundle['readingProgress'] as List? ?? [])
          .map(
              (e) => GalleryCache.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final savedAt = DateTime.now().microsecondsSinceEpoch;
      final backupDir =
          Directory(path.join(Global.appSupportPath, 'recovery-backups'));
      await backupDir.create(recursive: true);
      final backup = path.join(backupDir.path, 'before-$savedAt.isar');
      progress('备份本测试包数据库并原子写入…');
      await db.copyToFile(backup);
      // Only task/image rows for incoming GIDs are replaced. Unrelated/new GIDs
      // and other collections remain intact. Unique (gid, ser) indexes dedupe.
      await db.writeTxn(() async {
        for (final task in tasks) {
          await db.galleryImageTasks.filter().gidEqualTo(task.gid).deleteAll();
        }
        await db.galleryTasks.putAll(tasks);
        await db.galleryImageTasks.putAll(images);
        for (final history in histories) {
          final old = await db.viewHistorys.get(history.gid);
          if (old == null || old.lastViewTime < history.lastViewTime) {
            await db.viewHistorys.put(history);
          }
        }
      });
      if (localRecoveryTest) {
        // Pinned Isar diagnostic is intentionally used only by our test build.
        // ignore: experimental_member_use, invalid_use_of_visible_for_testing_member
        await db.verify();
      }
      for (final cache in caches) {
        if (cache.gid == null) continue;
        final old = hiveHelper.getCache(cache.gid!);
        if (old == null || (old.time ?? 0) < (cache.time ?? 0)) {
          hiveHelper.saveCache(cache);
        }
      }
      final current = Global.profile;
      final selectedProfile =
          importSettings && existingTasks.isEmpty ? importedProfile : current;
      Global.profile = selectedProfile.copyWith(
        user: current.user,
        downloadConfig: selectedProfile.downloadConfig.copyWith(
          downloadLocation: root.toString().oN,
        ),
      );
      Global.saveProfile();
      await hiveHelper.setDownloadTaskMigration(true);
      await Hive.box<String>(configBox).flush();
      await Hive.box<String>(galleryCacheBox).flush();
      final controller = Get.find<DownloadController>();
      final allTasks = await db.galleryTasks.where().findAll();
      controller.dState.galleryTaskMap
        ..clear()
        ..addEntries(allTasks.map((e) => MapEntry(e.gid, e)));
      controller.resetDownloadViewAnimationKey();
      if (Get.isRegistered<DownloadViewController>()) {
        Get.find<DownloadViewController>().update();
      }
      final report = await audit();
      report.addAll({
        'importedTasks': tasks.length,
        'preservedConflictingNewerGids': skipped,
        'beforeDatabaseBackup': backup,
        'sourceFormat': bundle['format'],
        'originalSdFilesModified': false,
      });
      await File(reportPath).writeAsString(jsonEncode(report), flush: true);
      progress('恢复完成：${report['taskCount']} 个任务，无重复主键');
      return report;
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>> audit({bool decodeSamples = false}) async {
    _guard();
    final db = isarHelper.isar;
    if (localRecoveryTest) {
      // ignore: experimental_member_use, invalid_use_of_visible_for_testing_member
      await db.verify();
    }
    final tasks = await db.galleryTasks.where().findAll();
    final images = await db.galleryImageTasks.where().findAll();
    final keys = images.map((e) => '${e.gid}:${e.ser}').toSet();
    final taskGids = tasks.map((e) => e.gid).toSet();
    final errors = <String>[];
    if (keys.length != images.length) errors.add('duplicate image keys');
    if (taskGids.length != tasks.length) errors.add('duplicate gallery keys');
    if (images.any((e) => !taskGids.contains(e.gid)))
      errors.add('orphan images');
    for (final task in tasks) {
      final rows = images.where((e) => e.gid == task.gid).toList();
      if (rows.length != task.fileCount) errors.add('row count ${task.gid}');
      final available =
          rows.where((e) => e.filePath?.isNotEmpty ?? false).length;
      if (available != task.completCount)
        errors.add('complete count ${task.gid}');
      if (task.status == 3 &&
          (available != task.fileCount ||
              recoveryNote(task.jsonString)?['expectedPageCountKnown'] ==
                  false)) {
        errors.add('false completion ${task.gid}');
      }
    }
    final samples = <Map<String, dynamic>>[];
    if (decodeSamples) {
      final chosen = <GalleryTask>[];
      // Small/non-H sample first, then a partial and unknown-total local entry.
      chosen.addAll(tasks
          .where((e) => (e.category ?? '').toLowerCase().contains('non-h'))
          .take(1));
      chosen.addAll(tasks
          .where((e) =>
              e.status == 6 &&
              recoveryNote(e.jsonString)?['expectedPageCountKnown'] != false)
          .take(1));
      chosen.addAll(tasks
          .where((e) =>
              recoveryNote(e.jsonString)?['expectedPageCountKnown'] == false)
          .take(1));
      if (chosen.isEmpty && tasks.isNotEmpty) chosen.add(tasks.first);
      for (final task in chosen) {
        final row = images.firstWhere(
            (e) => e.gid == task.gid && (e.filePath?.isNotEmpty ?? false));
        final uri = Uri.parse('${task.dirPath}%2F${row.filePath}');
        final bytes = await ss.getDocumentContent(uri);
        if (bytes == null || bytes.isEmpty) throw StateError('样本图片读取失败');
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        samples.add({
          'gid': task.gid,
          'ser': row.ser,
          'bytes': bytes.length,
          'width': frame.image.width,
          'height': frame.image.height,
          'sha256': sha256.convert(bytes).toString(),
        });
        frame.image.dispose();
        codec.dispose();
      }
    }
    final grants = await ss.persistedUriPermissions() ?? [];
    final report = <String, dynamic>{
      'checkedAt': DateTime.now().toIso8601String(),
      'packageName': Global.packageInfo.packageName,
      'taskCount': tasks.length,
      'imageTaskCount': images.length,
      'uniqueGalleryIds': taskGids.length,
      'uniqueImageKeys': keys.length,
      'completedTasks': tasks.where((e) => e.status == 3).length,
      'pausedTasks': tasks.where((e) => e.status == 6).length,
      'unknownTotalTasks': tasks
          .where((e) =>
              recoveryNote(e.jsonString)?['expectedPageCountKnown'] == false)
          .length,
      'availableImageReferences':
          images.where((e) => e.filePath?.isNotEmpty ?? false).length,
      'missingImageReferences':
          images.where((e) => e.filePath == null || e.filePath!.isEmpty).length,
      'errors': errors,
      'databaseIntegrityVerified': localRecoveryTest,
      'persistedGrants': grants.map((e) => e.toMap()).toList(),
      'decodedSamples': samples,
      'tasks': tasks
          .map((e) => {
                'gid': e.gid,
                'fileCount': e.fileCount,
                'present': e.completCount,
                'status': e.status,
                'dirPath': e.dirPath,
                'recovery': recoveryNote(e.jsonString)
              })
          .toList(),
    };
    if (errors.isNotEmpty) throw StateError('数据库校验未通过：${errors.join(', ')}');
    await Directory(Global.extStorePath).create(recursive: true);
    await File(reportPath).writeAsString(jsonEncode(report), flush: true);
    return report;
  }

  Future<String> exportCheckpoint() async {
    _guard();
    if (_busy) throw StateError('请等待当前恢复操作结束');
    final db = isarHelper.isar;
    final tasks = await db.galleryTasks.where().findAll();
    if (tasks.any((e) => e.status == 1 || e.status == 2)) {
      throw StateError('请暂停下载后再导出一致的检查点');
    }
    final root =
        Uri.parse(Global.profile.downloadConfig.downloadLocation ?? '');
    final treeId = _treeId(root);
    final images = await db.galleryImageTasks.where().findAll();
    final histories = await db.viewHistorys.where().findAll();
    final caches = Hive.box<String>(galleryCacheBox)
        .values
        .map(
            (e) => GalleryCache.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();
    final entries = <Map<String, dynamic>>[];
    for (final task in tasks) {
      final segments = Uri.parse(task.dirPath ?? '').pathSegments;
      if (segments.length != 4 ||
          segments[1] != treeId ||
          !segments.last.startsWith('$treeId/')) {
        throw StateError('存在不属于当前下载目录的任务，请先核对');
      }
      final relative = segments.last.substring(treeId.length + 1);
      if (!_safeName(relative)) throw StateError('任务路径不符合恢复约定');
      entries.add({
        'gid': task.gid,
        'relativeDirectory': relative,
        'galleryTask': task.toJson(),
        'imageTasks': (images.where((e) => e.gid == task.gid).toList()
              ..sort((a, b) => a.ser.compareTo(b.ser)))
            .map((e) => e.toJson())
            .toList(),
      });
    }
    final checkpoint = {
      'format': 'eros-fe-local-checkpoint',
      'schemaVersion': 1,
      'appPackageName': Global.packageInfo.packageName,
      'testBuild': localRecoveryTest,
      'createdAt': DateTime.now().toIso8601String(),
      'downloadRoot': {'treeUri': root.toString()},
      'profile': Global.profile.copyWith(user: kDefUser).toJson(),
      'preferredDownloadTasks': entries,
      'readHistory': histories.map((e) => e.toJson()).toList(),
      'readingProgress': caches.map((e) => e.toJson()).toList(),
      'warning':
          'No login credentials or comic image bytes. Keep SD directories.',
    };
    final bytes = utf8.encode(jsonEncode(checkpoint));
    final name =
        'fehviewer_local_checkpoint_${DateTime.now().millisecondsSinceEpoch}.json';
    final saved = await ss.createFileAsBytes(root,
        mimeType: 'application/json', displayName: name, bytes: bytes);
    if (saved == null) throw StateError('写入检查点失败');
    final reread = await ss.getDocumentContent(saved.uri);
    if (reread == null ||
        sha256.convert(reread).toString() != sha256.convert(bytes).toString()) {
      throw StateError('检查点回读校验失败');
    }
    await File(path.join(Global.extStorePath, 'recovery-checkpoint.json'))
        .writeAsBytes(bytes, flush: true);
    return name;
  }
}
