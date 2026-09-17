import 'package:eros_fe/route/routes.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';

import 'recovery_flags.dart';
import 'recovery_service.dart';

class LocalRecoveryPage extends StatefulWidget {
  const LocalRecoveryPage({super.key});

  @override
  State<LocalRecoveryPage> createState() => _LocalRecoveryPageState();
}

class _LocalRecoveryPageState extends State<LocalRecoveryPage> {
  final service = RecoveryService();
  bool busy = false;
  String message = '先导入恢复资料，再检查下载列表。漫画文件不会被删除。';
  Map<String, dynamic>? report;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => message = '未完成：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load({bool staged = false}) async {
    final bundle =
        staged ? await service.stagedInput() : await service.chooseInput();
    if (bundle == null || !mounted) return;
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('只恢复当前应用的数据库'),
        content: Text(localRecoveryTest
            ? '当前是独立测试包。将去重导入下载记录，保留缺页和未知总页数标记。不删除 SD 文件，不改动官方版或旧验证版。'
            : '恢复前会备份当前数据库。已有新任务保留，冲突项跳过。不会删除 SD 卡上的漫画。'),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始恢复')),
        ],
      ),
    );
    if (yes != true) return;
    final root = await service.selectRoot(bundle);
    if (root == null || !mounted) return;
    report = await service.importBundle(bundle, root, (text) {
      if (mounted) setState(() => message = text);
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(localRecoveryTest ? '独立数据库恢复测试' : '本地下载恢复与备份'),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                localRecoveryTest
                    ? '测试包：只读漫画文件\n官方版与已登录验证版均不受影响'
                    : '恢复与备份仅作用于当前应用',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 18),
              const Text('未知总页数的目录保留为本地阅读项；缺页项目不会被伪装成完整下载。'),
              const SizedBox(height: 20),
              CupertinoButton.filled(
                  onPressed: busy ? null : () => run(() => load()),
                  child: const Text('选择恢复 JSON')),
              if (localRecoveryTest) ...[
                const SizedBox(height: 12),
                CupertinoButton.filled(
                    onPressed:
                        busy ? null : () => run(() => load(staged: true)),
                    child: const Text('导入 ADB 暂存恢复文件')),
              ],
              const SizedBox(height: 12),
              CupertinoButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                          setState(() => message = '校验数据库并解码样本图片…');
                          report = await service.audit(decodeSamples: true);
                          setState(() => message = '数据库校验和样本解码通过。');
                        }),
                child: const Text('校验数据库与离线样本'),
              ),
              CupertinoButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                          setState(() => message = '导出当前记录、历史和阅读进度…');
                          final name = await service.exportCheckpoint();
                          setState(() => message = '已保存到 SD 下载目录并回读校验：\n$name');
                        }),
                child: const Text('导出最新恢复检查点到 SD 卡'),
              ),
              CupertinoButton(
                  onPressed: busy ? null : () => Get.offAllNamed(EHRoutes.root),
                  child: const Text('进入应用检查下载列表')),
              if (busy) const CupertinoActivityIndicator(),
              const SizedBox(height: 14),
              Text(message),
              if (report != null) ...[
                const SizedBox(height: 20),
                Text(
                  '数据库任务：${report!['taskCount']}\n'
                  '已齐页文件：${report!['completedTasks']}\n'
                  '暂停 / 本地项：${report!['pausedTasks']}\n'
                  '总页数未知：${report!['unknownTotalTasks']}\n'
                  '图片记录：${report!['imageTaskCount']}\n'
                  '可用页面：${report!['availableImageReferences']}\n'
                  '缺页引用：${report!['missingImageReferences']}\n'
                  '校验错误：${(report!['errors'] as List).length}',
                  style: const TextStyle(fontSize: 18),
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                  '换回官方版前，请先导出最新检查点并保留 SD 卡目录。官方版仍需具备对应的恢复能力；不要先卸载再假设能够恢复全部私有数据。'),
            ],
          ),
        ),
      ),
    );
  }
}
