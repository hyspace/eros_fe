import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:eros_fe/common/controller/download/download_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-diagnostics-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('structured logs are serialized and exclude sensitive fields', () async {
    final diagnostics =
        DownloadDiagnostics(File('${directory.path}/trace.log'));
    for (int page = 1; page <= 20; page++) {
      diagnostics.record('cache_miss', gid: 123, page: page, details: {
        'phase': 'before_metadata',
        'reason': 'missing',
        'cookie': 'PRIVATE_COOKIE',
        'url': 'https://user:PRIVATE_PASSWORD@example.test/?key=PRIVATE_KEY',
        'source_id': 'PRIVATE_SOURCE',
        'filename': 'PRIVATE_TITLE',
      });
    }
    await diagnostics.flush();
    final text = await diagnostics.file.readAsString();
    final events = const LineSplitter()
        .convert(text)
        .map((line) => jsonDecode(line) as Map)
        .toList();
    expect(
        events.map((event) => event['page']), List.generate(20, (i) => i + 1));
    expect(text, isNot(contains('PRIVATE')));
    expect(diagnostics.writeFailures, 0);
  });

  test('network errors keep protocol details but not raw errors or credentials',
      () async {
    final diagnostics =
        DownloadDiagnostics(File('${directory.path}/trace.log'));
    diagnostics.record('network_error', gid: 123, page: 19, details: {
      ...DownloadDiagnostics.endpoint(
          'https://user:PRIVATE_PASSWORD@image.example.test:443/private?key=PRIVATE'),
      ...DownloadDiagnostics.failure(DioException(
        requestOptions: RequestOptions(path: 'PRIVATE_URL'),
        error: const HandshakeException('PRIVATE WRONG_VERSION_NUMBER'),
      )),
    });
    await diagnostics.flush();
    final text = await diagnostics.file.readAsString();
    final event = jsonDecode(text) as Map;
    expect(event['scheme'], 'https');
    expect(event['host'], 'image.example.test');
    expect(event['port'], 443);
    expect(event['exception'], 'HandshakeException');
    expect(event['tls_error'], 'wrong_version_number');
    expect(text, isNot(contains('PRIVATE')));
  });

  test('invalid endpoint diagnostics cannot break the download flow', () {
    expect(DownloadDiagnostics.endpoint('https://host:invalid/a'), isEmpty);
  });

  test('diagnostic write failure does not fail downloads or poison the queue',
      () async {
    final blocker = await File('${directory.path}/blocked').writeAsString('x');
    final diagnostics = DownloadDiagnostics(File('${blocker.path}/trace.log'));
    diagnostics.record('page_start');
    await diagnostics.flush();
    expect(diagnostics.writeFailures, 1);
    await blocker.delete();
    diagnostics.record('page_complete');
    await diagnostics.flush();
    expect((jsonDecode(await diagnostics.file.readAsString()) as Map)['event'],
        'page_complete');
  });

  test('log rotation retains at most the active log and one previous log',
      () async {
    final diagnostics =
        DownloadDiagnostics(File('${directory.path}/trace.log'), maxBytes: 200);
    for (int i = 0; i < 30; i++) {
      diagnostics.record('page_complete', gid: 123, page: i);
    }
    await diagnostics.flush();
    expect(await directory.list().length, 2);
    expect(
        await File('${diagnostics.file.path}.previous.log').exists(), isTrue);
    expect(
        (jsonDecode((await diagnostics.file.readAsLines()).last)
            as Map)['page'],
        29);
  });
}
