/// The ad lists 広告ブロック bundles (#1050), and the files made from them.
/// See assets/ad_block/README.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tabhand/ad_block/ad_list_converter.dart';

/// A list the app bundles: where it comes from, under what license, and for
/// which OS.
typedef AdList = ({String id, String title, String url, String license, List<String> platforms});

/// The lists, in the order their rules are read. AdGuard Japanese filter is
/// GPLv3, which the App Store does not go with, so it is Android-only (#1050).
const adLists = <AdList>[
  (
    id: 'easylist',
    title: 'EasyList',
    url: 'https://easylist.to/easylist/easylist.txt',
    license: 'CC BY-SA 4.0 (EasyList: GPL-3.0-or-later or CC BY-SA 3.0 or later)',
    platforms: ['android', 'ios'],
  ),
  (
    id: 'adguard_japanese',
    title: 'AdGuard Japanese filter',
    url: 'https://filters.adtidy.org/extension/chromium/filters/7.txt',
    license: 'GPL-3.0',
    platforms: ['android'],
  ),
];

/// A list as fetched: its text, and the day (UTC, `yyyy-mm-dd`) it was.
typedef SourceSnapshot = ({String text, String fetchedOn});

/// Where the fetched lists are kept (relative to the app), and where the
/// files made from them go.
const sourcesDir = 'tool/ad_block/sources';
const bundleDir = 'assets/ad_block';
const _fetchedOnFile = 'fetched_on.json';

/// Whether [path] (relative to [bundleDir]) is one [buildBundledFiles] makes;
/// the rest there (README, licenses) is written by hand.
bool isGenerated(String path) =>
    path == 'ad_lists.json' ||
    RegExp(r'^ios/rules-\d+\.json$').hasMatch(path) ||
    RegExp(r'^android/(network|cosmetic)\.tsv$').hasMatch(path);

/// The files to bundle, by path relative to [bundleDir]. The same snapshots
/// always make the same files.
Map<String, String> buildBundledFiles(
  Map<String, SourceSnapshot> sources, {
  int maxRulesPerList = webKitMaxRulesPerList,
}) {
  List<AdList> listsFor(String platform) => adLists.where((l) => l.platforms.contains(platform)).toList();
  RuleSet parse(List<AdList> lists) => parseFilterLists([for (final l in lists) sources[l.id]!.text]);

  final iosRules = parse(listsFor('ios'));
  final iosSkipped = Map.of(iosRules.skipped);
  final ios = webKitRuleLists(iosRules, maxRulesPerList: maxRulesPerList, skipped: iosSkipped);
  final androidRules = parse(listsFor('android'));
  final header = [
    for (final list in listsFor('android')) '# ${list.title} ${_version(sources[list.id]!.text)} (${list.license})',
  ].join('\n');
  final android = androidFileTexts(androidRules, about: header);

  int ruleLines(String file) => file.split('\n').where((l) => l.isNotEmpty && !l.startsWith('#')).length;
  Map<String, int> sorted(Map<String, int> counts) => {
    for (final key in counts.keys.toList()..sort()) key: counts[key]!,
  };
  final metadata = {
    'lists': [
      for (final list in adLists)
        {
          'id': list.id,
          'title': list.title,
          'version': _version(sources[list.id]!.text),
          'fetchedOn': sources[list.id]!.fetchedOn,
          'url': list.url,
          'license': list.license,
          'platforms': list.platforms,
        },
    ],
    'ios': {
      'files': [for (var i = 0; i < ios.length; i++) 'ios/rules-${i + 1}.json'],
      'rules': [for (final list in ios) list.length],
      'skipped': sorted(iosSkipped),
    },
    'android': {
      'network': ruleLines(android.network),
      'cosmetic': ruleLines(android.cosmetic),
      'skipped': sorted(androidRules.skipped),
    },
  };

  return {
    'ad_lists.json': '${const JsonEncoder.withIndent('  ').convert(metadata)}\n',
    for (var i = 0; i < ios.length; i++) 'ios/rules-${i + 1}.json': webKitListJson(ios[i]),
    'android/network.tsv': android.network,
    'android/cosmetic.tsv': android.cosmetic,
  };
}

/// The `! Version:` of a list's header.
String _version(String text) => RegExp(r'^! Version: *(.+)$', multiLine: true).firstMatch(text)?[1]!.trim() ?? '';

/// Why a freshly fetched [text] of [list] must not replace the [kept] one, or
/// null when it may. A page that is not the list (a Wi-Fi login, an error
/// page) has no `! Title:` of the list; a list that lost more than a fifth of
/// its rules is held back unless [allowShrink].
String? fetchedListProblem(AdList list, String text, {required String kept, bool allowShrink = false}) {
  final header = text.split('\n').take(40);
  if (!header.contains('! Title: ${list.title}') || _version(text).isEmpty) {
    return '${list.title}: the fetched text has no "! Title: ${list.title}" and "! Version:" header; it is not the list';
  }
  final before = _ruleCount(kept);
  final after = _ruleCount(text);
  if (!allowShrink && after * 5 < before * 4) {
    return '${list.title}: rules went from $before to $after (more than a fifth fewer); '
        'check the list, then rerun with --allow-shrink';
  }
  return null;
}

/// The lines of a list that are rules (not comments, not the `[Adblock Plus]` line).
int _ruleCount(String text) =>
    text.split('\n').where((l) => l.trim().isNotEmpty && !l.startsWith('!') && !l.startsWith('[')).length;

/// The snapshots kept in [dir] ([sourcesDir]).
Map<String, SourceSnapshot> readSnapshots(Directory dir) {
  final fetchedOn = (jsonDecode(File('${dir.path}/$_fetchedOnFile').readAsStringSync()) as Map).cast<String, String>();
  return {
    for (final list in adLists)
      list.id: (text: File('${dir.path}/${list.id}.txt').readAsStringSync(), fetchedOn: fetchedOn[list.id]!),
  };
}

/// Keeps [snapshots] in [dir], for [readSnapshots].
void writeSnapshots(Directory dir, Map<String, SourceSnapshot> snapshots) {
  dir.createSync(recursive: true);
  for (final MapEntry(key: id, value: snapshot) in snapshots.entries) {
    File('${dir.path}/$id.txt').writeAsStringSync(snapshot.text);
  }
  final fetchedOn = {for (final MapEntry(:key, :value) in snapshots.entries) key: value.fetchedOn};
  File('${dir.path}/$_fetchedOnFile').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(fetchedOn)}\n');
}
