/// Makes the bundled files of 広告ブロック (assets/ad_block/) from the lists
/// kept in tool/ad_block/sources/ (#1050). Run from the app directory:
///
///     fvm dart run tool/ad_block/build_ad_lists.dart          # from the kept lists
///     fvm dart run tool/ad_block/build_ad_lists.dart --fetch  # fetch them anew first
///
/// With --fetch, nothing is written unless every list passes
/// [fetchedListProblem]; --allow-shrink lets a list lose more than a fifth of
/// its rules. The update flow around this is tool/ad_block/update_ad_lists.sh
/// (assets/ad_block/README.md「リストを更新する」).
///
/// The app never fetches these lists itself: new ones come with an app
/// update. (足した広告リスト, #1056, are fetched by the device from the
/// address the user gave, and converted there with the same converter.)
library;

import 'dart:convert';
import 'dart:io';

import 'ad_lists.dart';

const _usage = 'usage: dart run tool/ad_block/build_ad_lists.dart [--fetch [--allow-shrink]]';

Future<void> main(List<String> args) async {
  final fetch = args.contains('--fetch');
  final allowShrink = args.contains('--allow-shrink');
  if (args.any((a) => a != '--fetch' && a != '--allow-shrink') || (allowShrink && !fetch)) {
    stderr.writeln(_usage);
    exit(64);
  }
  final sources = Directory(sourcesDir);
  final metadataFile = File('$bundleDir/ad_lists.json');
  final before = metadataFile.existsSync() ? jsonDecode(metadataFile.readAsStringSync()) as Map<String, dynamic> : null;
  if (fetch) {
    final kept = readSnapshots(sources);
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final client = HttpClient();
    final Map<String, SourceSnapshot> fetched;
    try {
      fetched = {for (final list in adLists) list.id: (text: await _fetch(client, list.url), fetchedOn: today)};
    } finally {
      client.close();
    }
    if (adLists.every((l) => fetched[l.id]!.text == kept[l.id]!.text)) {
      stdout.writeln('どのリストも、取ってある元のリストと同じだった。何も変えていない。');
      return;
    }
    final problems = [
      for (final list in adLists)
        ?fetchedListProblem(list, fetched[list.id]!.text, kept: kept[list.id]!.text, allowShrink: allowShrink),
    ];
    if (problems.isNotEmpty) {
      stderr.writeln('Kept the lists as they were:\n${problems.map((p) => '  $p').join('\n')}');
      exit(1);
    }
    writeSnapshots(sources, fetched);
  }

  final files = buildBundledFiles(readSnapshots(sources));
  final bundle = Directory(bundleDir);
  for (final stale in bundle.existsSync() ? bundle.listSync(recursive: true).whereType<File>() : const <File>[]) {
    if (isGenerated(stale.path.substring(bundle.path.length + 1))) stale.deleteSync();
  }
  for (final MapEntry(key: path, value: content) in files.entries) {
    File('${bundle.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }
  stdout.writeln(_summary(before, jsonDecode(files['ad_lists.json']!) as Map<String, dynamic>));
}

Future<String> _fetch(HttpClient client, String url) async {
  final response = await (await client.getUrl(Uri.parse(url))).close();
  if (response.statusCode != HttpStatus.ok) throw HttpException('${response.statusCode}', uri: Uri.parse(url));
  return response.transform(utf8.decoder).join().then((text) => text.replaceAll('\r\n', '\n'));
}

/// What changed between two `ad_lists.json`, with a commit message for it.
String _summary(Map<String, dynamic>? before, Map<String, dynamic> after) {
  String version(Map<String, dynamic>? m, String id) =>
      ((m?['lists'] as List?)?.cast<Map>().where((l) => l['id'] == id).firstOrNull?['version'] as String?) ?? '-';
  String count(Object? n) => n is int ? n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',') : '-';
  String change(Object? from, Object? to) => from == to ? count(to) : '${count(from)} → ${count(to)}';
  int iosRules(Map<String, dynamic>? m) =>
      ((m?['ios'] as Map?)?['rules'] as List?)?.cast<int>().fold<int>(0, (a, b) => a + b) ?? -1;
  Object? android(Map<String, dynamic>? m, String key) => (m?['android'] as Map?)?[key];

  final lists = [for (final list in adLists) (title: list.title, from: version(before, list.id), to: version(after, list.id))];
  final changed = lists.where((l) => l.from != l.to).toList();
  final lines = [
    for (final l in lists) '${l.title}: ${l.from == l.to ? '${l.to}（変わらない）' : '${l.from} → ${l.to}'}',
    'iOS: ${change(iosRules(before), iosRules(after))} 規則（${((after['ios'] as Map)['files'] as List).join('・')}）',
    'Android: 通信 ${change(android(before, 'network'), android(after, 'network'))}・'
        '見た目 ${change(android(before, 'cosmetic'), android(after, 'cosmetic'))} 規則',
  ];
  if (changed.isEmpty) return '${lines.join('\n')}\n\nどのリストも版が変わっていない。コミットは要らない。';
  final subject = 'chore(aside_flutter): 広告ブロックのリストを更新する（${changed.map((l) => '${l.title} ${l.to}').join('・')}）';
  return '${lines.join('\n')}\n\nコミットのメッセージの案:\n\n$subject\n\n${lines.join('\n')}';
}
