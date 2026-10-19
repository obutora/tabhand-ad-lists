/// Converts ad lists in the Adblock Plus / AdGuard syntax (EasyList, AdGuard
/// Japanese filter) into what 広告ブロック reads: the `WKContentRuleList`
/// JSON iOS compiles, and the two TSV files the Android matcher reads. Only
/// what the lists say with requests and plain CSS selectors is kept;
/// scriptlets and other rules that need JavaScript are dropped (ADR 0012,
/// ADR 0013). See assets/ad_block/README.md.
///
/// Pure Dart, so both use the same code: tool/ad_block/ makes the bundled
/// lists with it (#1050), and the app converts 足した広告リスト on the
/// device (#1056, lib/ad_block/added_ad_lists.dart).
library;

import 'dart:convert';

/// The request types of the lists, in the order both outputs write them.
/// `document` is a top-level page; `subdocument` a frame.
const requestTypes = [
  'script',
  'image',
  'stylesheet',
  'object',
  'xmlhttprequest',
  'subdocument',
  'ping',
  'media',
  'font',
  'websocket',
  'other',
  'document',
];

/// What `~type` options leave out of: every type but a top-level page.
final _subresourceTypes = requestTypes.where((t) => t != 'document').toList();

const _typeAliases = {
  'css': 'stylesheet',
  'xhr': 'xmlhttprequest',
  'frame': 'subdocument',
  'doc': 'document',
  'object-subrequest': 'object',
};

/// A network rule: blocks requests, or (allow) lets them through.
class NetworkRule {
  NetworkRule({
    required this.allow,
    required this.regex,
    this.host,
    this.tokens = const [],
    this.types,
    this.party,
    this.domains = const [],
    this.matchCase = false,
  });

  final bool allow;

  /// Set when the rule is `||host^`: the request's host is [host] or one of
  /// its subdomains. [regex] says the same thing.
  final String? host;

  /// Searched (not anchored) in the whole request URL.
  final String regex;

  /// The words every URL the rule matches has as a whole run of `[a-z0-9%]`
  /// (lowercased); the Android matcher indexes the rule by one of them.
  final List<String> tokens;

  /// Of [requestTypes], in that order; null is every request, pages too.
  final List<String>? types;

  /// `first` or `third`; null is either.
  final String? party;

  /// The page's domain: `a.jp` is a.jp or a subdomain, `~a.jp` is not it.
  /// Empty is any page.
  final List<String> domains;

  final bool matchCase;
}

/// A rule that hides elements with a CSS selector.
class HideRule {
  HideRule(this.domains, this.selector);

  /// The page's domain, written as in [NetworkRule.domains]. A rule naming
  /// no domain to include is generic: it hides on every site.
  final List<String> domains;

  final String selector;

  bool get isGeneric => domains.every((d) => d.startsWith('~'));
}

/// What the lists hold once parsed: the input of both outputs.
class RuleSet {
  final networkRules = <NetworkRule>[];
  final hideRules = <HideRule>[];

  /// Hosts (and their subdomains) whose pages hide nothing: `$elemhide`
  /// and `$document` exceptions.
  final noHideHosts = <String>{};

  /// Hosts whose pages leave out the hiding rules for every site:
  /// `$generichide` exceptions.
  final noGenericHideHosts = <String>{};

  /// Why rules were left out, and how many.
  final skipped = <String, int>{};

  void skip(String reason) => skipped[reason] = (skipped[reason] ?? 0) + 1;
}

/// Reads [lists] (their texts, in order) as one: an exception in one list
/// applies to the rules of all, and a line seen before is read once.
RuleSet parseFilterLists(List<String> lists) {
  final rules = RuleSet();
  final unhides = <HideRule>[];
  final seen = <String>{};
  for (final list in lists) {
    for (final raw in list.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('!')) continue;
      if (!seen.add(line)) {
        rules.skip('duplicate');
        continue;
      }
      if (line.startsWith('[')) {
        // `[Adblock Plus 2.0]`, or AdGuard's `[$path=…]` before a cosmetic rule.
        if (line.contains('#')) rules.skip('cosmetic modifiers');
        continue;
      }
      final cosmetic = _cosmeticRule.firstMatch(line);
      if (cosmetic != null) {
        _parseCosmeticRule(cosmetic, rules, unhides);
      } else if (line.contains(r'$$') || line.contains(r'$@$')) {
        rules.skip('HTML filtering');
      } else {
        _parseNetworkRule(line, rules);
      }
    }
  }
  _applyUnhides(rules, unhides);
  return rules;
}

/// `domains##selector` and its kin: `#@#` unhides, `#?#` is extended CSS,
/// `#$#` a snippet (ABP) or style injection (AdGuard), `#%#` a script.
final _cosmeticRule = RegExp(r'^([^/|@"!]*?)#(@)?(\$\?|[?$%])?#(.*)$');

/// Pseudo-classes of extended CSS: they take JavaScript to work.
final _extendedPseudo = RegExp(
  r':(-abp-[a-z-]+|has-text|contains|xpath|matches-[a-z-]+|upward|remove(-attr|-class)?|style|'
  r'min-text-length|watch-attrs?|if|if-not|nth-ancestor|others|properties)\(',
);

void _parseCosmeticRule(RegExpMatch match, RuleSet rules, List<HideRule> unhides) {
  final unhide = match[2] != null;
  final kind = match[3];
  var selector = match[4]!.trim();
  if (kind == '%' || selector.startsWith('+js(')) return rules.skip('scriptlet');
  if (kind == r'$' || kind == r'$?') return rules.skip('snippet or style injection');
  if (selector.startsWith('^')) return rules.skip('HTML filtering');
  selector = selector.replaceAll(':-abp-has(', ':has(');
  if (selector.isEmpty ||
      _extendedPseudo.hasMatch(selector) ||
      selector.contains(RegExp(r'[{}<\t\n]'))) {
    return rules.skip('not a CSS selector');
  }
  final domains = _parseDomains(match[1]!.isEmpty ? const [] : match[1]!.split(','));
  if (domains == null) return rules.skip('domain');
  (unhide ? unhides : rules.hideRules).add(HideRule(domains, selector));
}

/// `#@#` takes the selector off the pages it names (all pages when it names
/// none); what is left is written into the hiding rules' domains.
void _applyUnhides(RuleSet rules, List<HideRule> unhides) {
  final exceptionsBySelector = <String, List<HideRule>>{};
  for (final unhide in unhides) {
    exceptionsBySelector.putIfAbsent(unhide.selector, () => []).add(unhide);
  }
  final kept = <HideRule>[];
  for (final hide in rules.hideRules) {
    final exceptions = exceptionsBySelector[hide.selector];
    if (exceptions == null) {
      kept.add(hide);
      continue;
    }
    if (exceptions.any((e) => e.isGeneric)) {
      rules.skip('unhidden');
      continue;
    }
    final domains = [...hide.domains];
    for (final domain in exceptions.expand((e) => e.domains)) {
      if (domains.remove(domain)) continue;
      final within = hide.isGeneric || hide.domains.any((d) => !d.startsWith('~') && domain.endsWith('.$d'));
      if (within && !domains.contains('~$domain')) domains.add('~$domain');
    }
    if (!hide.isGeneric && domains.every((d) => d.startsWith('~'))) {
      rules.skip('unhidden');
      continue;
    }
    kept.add(HideRule(domains, hide.selector));
  }
  rules.hideRules
    ..clear()
    ..addAll(kept);
}

final _optionsStart = RegExp(r'\$(~?[a-z0-9_-]+(=[^,]*)?)(,~?[a-z0-9_-]+(=[^,]*)?)*$');

void _parseNetworkRule(String line, RuleSet rules) {
  final allow = line.startsWith('@@');
  var text = allow ? line.substring(2) : line;
  var options = const <String>[];
  final optionsMatch = _optionsStart.allMatches(text).lastOrNull;
  if (optionsMatch != null) {
    options = text.substring(optionsMatch.start + 1).split(',');
    text = text.substring(0, optionsMatch.start);
  }

  final included = <String>{};
  final excluded = <String>{};
  var everyType = false;
  String? party;
  var domains = <String>[];
  var matchCase = false;
  final pageExceptions = <String>{};
  for (final option in options) {
    final negated = option.startsWith('~');
    final [name, ...valueParts] = (negated ? option.substring(1) : option).split('=');
    final value = valueParts.join('=');
    final type = _typeAliases[name] ?? name;
    if (requestTypes.contains(type) || type == 'popup') {
      (negated ? excluded : included).add(type);
    } else if (name == 'third-party' || name == '3p') {
      party = negated ? 'first' : 'third';
    } else if (name == 'first-party' || name == '1p') {
      party = negated ? 'third' : 'first';
    } else if (name == 'domain' || name == 'from') {
      final parsed = _parseDomains(value.split('|'));
      if (parsed == null) return rules.skip('domain');
      domains = parsed;
    } else if (name == 'match-case') {
      matchCase = !negated;
    } else if (name == 'all') {
      everyType = true;
    } else if (name == 'important') {
      // Allow rules always win here; nothing to carry.
    } else if (allow && !negated && (name == 'elemhide' || name == 'ehide')) {
      pageExceptions.add('elemhide');
    } else if (allow && !negated && (name == 'generichide' || name == 'ghide')) {
      pageExceptions.add('generichide');
    } else {
      return rules.skip('option \$$name');
    }
  }

  final pattern = _compilePattern(text);
  if (pattern == null) return rules.skip('pattern');
  NetworkRule rule(List<String>? types) => NetworkRule(
    allow: allow,
    regex: pattern.regex,
    host: pattern.host,
    tokens: pattern.tokens,
    types: types,
    party: party,
    domains: domains,
    matchCase: matchCase,
  );

  // An exception for the pages themselves (`$document`, `$elemhide`,
  // `$generichide`): the cosmetic side knows it by host only, from
  // `@@||host^` or from `@@$…,domain=host|host`.
  if (allow && (included.contains('document') || pageExceptions.isNotEmpty)) {
    final hosts = party != null
        ? const <String>[]
        : domains.isEmpty
        ? [?pattern.host]
        : pattern.regex == '.*' && domains.every((d) => !d.startsWith('~'))
        ? domains
        : const <String>[];
    void except(Set<String> into) => hosts.isEmpty ? rules.skip('page exception not for a host') : into.addAll(hosts);
    if (included.contains('document') || pageExceptions.contains('elemhide')) except(rules.noHideHosts);
    if (pageExceptions.contains('generichide')) except(rules.noGenericHideHosts);
    if (included.contains('document')) rules.networkRules.add(rule(['document']));
    included.remove('document');
    if (included.isEmpty && excluded.isEmpty) return;
  }

  List<String>? types;
  if (!everyType && included.isNotEmpty) {
    types = requestTypes.where(included.contains).toList();
    if (types.isEmpty) return rules.skip('popup');
  } else if (!everyType && excluded.isNotEmpty) {
    types = _subresourceTypes.where((t) => !excluded.contains(t)).toList();
  }
  rules.networkRules.add(rule(types));
}

final _domainName = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');

/// Domains as written in `domain=` or before `##`, lowercased; `example.*`
/// becomes `example.` + each of [_wildcardTlds], and ones WebKit cannot say
/// (non-ASCII, regexes) are left out. Null when only excluded domains would
/// remain of a list that named some to include.
List<String>? _parseDomains(Iterable<String> written) {
  final domains = <String>[];
  var hadIncluded = false;
  for (final entry in written) {
    final negated = entry.startsWith('~');
    final name = (negated ? entry.substring(1) : entry).trim().toLowerCase();
    if (!negated) hadIncluded = true;
    final names = name.endsWith('.*') ? [for (final tld in _wildcardTlds) '${name.substring(0, name.length - 1)}$tld'] : [name];
    for (final name in names.where(_domainName.hasMatch)) {
      domains.add(negated ? '~$name' : name);
    }
  }
  if (hadIncluded && domains.every((d) => d.startsWith('~'))) return null;
  return domains;
}

/// `||`: the scheme, then the host or a subdomain of it.
const _hostStart = r'^[a-z][a-z0-9.+-]*://([^/]*\.)?';

/// `^`, a separator: anything but a letter, a digit or `_.%-`.
const _separator = '[^a-zA-Z0-9_.%-]';

/// A separator or the end of the URL (WebKit has no `|`).
const _separatorOrEnd = '($_separator.*)?\$';

/// What `example.*` stands for: neither WebKit nor a host lookup takes a
/// wildcard, so it is the top-level domains most sites are under, Japan's
/// first.
const _wildcardTlds = [
  'jp',
  'co.jp',
  'ne.jp',
  'com',
  'net',
  'org',
  'co.uk',
  'de',
  'fr',
  'it',
  'es',
  'nl',
  'pl',
  'se',
  'ca',
  'com.au',
  'com.br',
  'com.mx',
  'in',
  'co.kr',
  'com.tw',
  'com.tr',
];

/// The regex for an ABP pattern, or null when there is none WebKit and Java
/// both read the same way (a `/regex/` rule, a `|` inside, non-ASCII).
({String regex, String? host, List<String> tokens})? _compilePattern(String pattern) {
  var body = pattern;
  final hostAnchor = body.startsWith('||');
  final startAnchor = !hostAnchor && body.startsWith('|');
  if (hostAnchor) body = body.substring(2);
  if (startAnchor) body = body.substring(1);
  final endAnchor = body.endsWith('|');
  if (endAnchor) body = body.substring(0, body.length - 1);
  if (body.contains('|') || body.codeUnits.any((c) => c > 0x7e || c < 0x20)) return null;
  if (!hostAnchor && !startAnchor && body.length > 2 && body.startsWith('/') && body.endsWith('/')) return null;
  body = body.replaceAll(RegExp(r'\*+'), '*');
  if (!hostAnchor && !startAnchor) body = body.replaceFirst(RegExp(r'^\*'), '');
  if (!endAnchor) body = body.replaceFirst(RegExp(r'\*$'), '');

  final lower = body.toLowerCase();
  final host = hostAnchor && !endAnchor ? RegExp(r'^([a-z0-9-]+(\.[a-z0-9-]+)+)\^$').firstMatch(lower)?.group(1) : null;

  final out = StringBuffer(hostAnchor ? _hostStart : (startAnchor ? '^' : ''));
  var inHost = hostAnchor;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == '*') {
      out.write('.*');
      inHost = false;
    } else if (c == '^') {
      if (inHost) {
        out.write('[:/]');
      } else if (i == body.length - 1 && !endAnchor) {
        out.write(_separatorOrEnd);
      } else {
        out.write(_separator);
      }
      inHost = false;
    } else {
      if (!RegExp('[a-zA-Z0-9.-]').hasMatch(c)) inHost = false;
      out.write(_escape(c));
    }
  }
  if (endAnchor) out.write(r'$');
  final regex = out.isEmpty ? '.*' : out.toString();

  // A run of token characters is a token when what bounds it on both sides
  // is a literal non-token character, a separator, or an anchor.
  final tokens = <String>[];
  for (final run in RegExp('[a-z0-9%]+').allMatches(lower)) {
    final before = run.start == 0 ? hostAnchor || startAnchor : lower[run.start - 1] != '*';
    final after = run.end == lower.length ? endAnchor : lower[run.end] != '*';
    if (before && after && run[0]!.length >= 2) tokens.add(run[0]!);
  }
  return (regex: regex, host: host, tokens: tokens);
}

String _escape(String literal) => literal.replaceAllMapped(RegExp(r'[.+?()\[\]{}\\|$^*]'), (m) => '\\${m[0]}');


/// WebKit's resource types for one of [requestTypes]. A frame is a
/// `document` to WebKit; what has no type of its own there is `raw`.
const _webKitTypes = {
  'script': ['script'],
  'image': ['image', 'svg-document'],
  'stylesheet': ['style-sheet'],
  'object': ['raw'],
  'xmlhttprequest': ['raw'],
  'subdocument': ['document'],
  'ping': ['raw'],
  'media': ['media'],
  'font': ['font'],
  'websocket': ['raw'],
  'other': ['raw'],
  'document': ['document'],
};
const _webKitTypeOrder = ['document', 'image', 'svg-document', 'style-sheet', 'script', 'font', 'raw', 'media'];

/// The trigger for a network rule, or null when WebKit cannot say it.
Map<String, Object?>? _webKitTrigger(NetworkRule rule) {
  final included = [for (final d in rule.domains) if (!d.startsWith('~')) '*$d'];
  final excluded = [for (final d in rule.domains) if (d.startsWith('~')) '*${d.substring(1)}'];
  if (included.isNotEmpty && excluded.isNotEmpty) return null;
  final types = rule.types == null ? null : {for (final t in rule.types!) ..._webKitTypes[t]!};
  return {
    'url-filter': rule.regex,
    if (rule.matchCase) 'url-filter-is-case-sensitive': true,
    if (types != null) 'resource-type': _webKitTypeOrder.where(types.contains).toList(),
    if (rule.party != null) 'load-type': ['${rule.party}-party'],
    if (included.isNotEmpty) 'if-domain': included,
    if (excluded.isNotEmpty) 'unless-domain': excluded,
  };
}

/// The most rules one `WKContentRuleList` takes (WebKit's
/// ContentExtensionParser.cpp `maxRuleCount`, since iOS 15).
const webKitMaxRulesPerList = 150000;

/// The rule lists iOS compiles with `WKContentRuleListStore`, in order;
/// more than one when the rules do not fit in [maxRulesPerList]. Rules
/// WebKit cannot say are counted in [skipped] by reason.
List<List<Map<String, Object?>>> webKitRuleLists(
  RuleSet rules, {
  int maxRulesPerList = webKitMaxRulesPerList,
  Map<String, int>? skipped,
}) {
  void skip(String reason) => skipped?[reason] = (skipped[reason] ?? 0) + 1;
  Map<String, Object?> rule(Map<String, Object?> trigger, String action) => {
    'trigger': trigger,
    'action': {'type': action},
  };
  Iterable<Map<String, Object?>> network({required bool allow}) sync* {
    for (final r in rules.networkRules.where((r) => r.allow == allow && !_isPageException(r))) {
      final trigger = _webKitTrigger(r);
      if (trigger == null) {
        skip('if-domain and unless-domain');
        continue;
      }
      yield rule(trigger, allow ? 'ignore-previous-rules' : 'block');
    }
  }

  // Last, so that nothing on those pages is blocked or hidden.
  Iterable<Map<String, Object?>> pageExceptions() sync* {
    for (final r in rules.networkRules.where(_isPageException)) {
      if (r.domains.isNotEmpty || r.party != null) {
        skip('page exception with conditions');
        continue;
      }
      yield rule({
        'url-filter': '.*',
        if (r.host != null) 'if-domain': ['*${r.host}'] else 'if-top-url': [r.regex],
      }, 'ignore-previous-rules');
    }
  }

  Iterable<Map<String, Object?>> hides({required bool generic}) sync* {
    for (final h in rules.hideRules.where((h) => h.isGeneric == generic)) {
      final included = [for (final d in h.domains) if (!d.startsWith('~')) '*$d'];
      final excluded = [for (final d in h.domains) if (d.startsWith('~')) '*${d.substring(1)}'];
      if (included.isNotEmpty && excluded.isNotEmpty) {
        skip('if-domain and unless-domain');
        continue;
      }
      yield {
        'trigger': {
          'url-filter': '.*',
          if (included.isNotEmpty) 'if-domain': included,
          if (excluded.isNotEmpty) 'unless-domain': excluded,
        },
        'action': {'type': 'css-display-none', 'selector': h.selector},
      };
    }
  }

  // Each ignore-previous-rules undoes only what comes before it in its own
  // list, so a list has its generic hides first, then their exceptions, its
  // other hides, their exceptions, its blocks, and every list ends with all
  // the network exceptions.
  List<Map<String, Object?>> ignoreOn(Set<String> hosts) => hosts.isEmpty
      ? const []
      : [
          rule({
            'url-filter': '.*',
            'if-domain': [for (final h in hosts) '*$h'],
          }, 'ignore-previous-rules'),
        ];
  final genericExceptions = ignoreOn(rules.noGenericHideHosts);
  final hideExceptions = ignoreOn(rules.noHideHosts);
  final exceptions = [...network(allow: true), ...pageExceptions()];
  final body = [
    for (final r in hides(generic: true)) (kind: 'generic', rule: r),
    for (final r in hides(generic: false)) (kind: 'specific', rule: r),
    for (final r in network(allow: false)) (kind: 'block', rule: r),
  ];
  final perList = maxRulesPerList - exceptions.length - genericExceptions.length - hideExceptions.length;
  if (perList < 1) throw ArgumentError.value(maxRulesPerList, 'maxRulesPerList', 'leaves no room past the exceptions');

  final lists = <List<Map<String, Object?>>>[];
  for (var start = 0; start < body.length || lists.isEmpty; start += perList) {
    final part = body.sublist(start, (start + perList).clamp(0, body.length));
    Iterable<Map<String, Object?>> of(String kind) => part.where((p) => p.kind == kind).map((p) => p.rule);
    final generic = of('generic').toList();
    final specific = of('specific').toList();
    lists.add([
      ...generic,
      if (generic.isNotEmpty) ...genericExceptions,
      ...specific,
      if (generic.isNotEmpty || specific.isNotEmpty) ...hideExceptions,
      ...of('block'),
      ...exceptions,
    ]);
  }
  return lists;
}

bool _isPageException(NetworkRule rule) => rule.allow && rule.types?.length == 1 && rule.types!.single == 'document';

/// The two files the Android matcher reads.
({String network, String cosmetic}) androidFiles(RuleSet rules) {
  final counts = <String, int>{};
  for (final rule in rules.networkRules) {
    if (rule.host != null) continue;
    for (final token in rule.tokens.toSet()) {
      counts[token] = (counts[token] ?? 0) + 1;
    }
  }
  // The rarest token keeps the matcher's buckets small; then the longest.
  String indexToken(NetworkRule rule) {
    if (rule.host != null || rule.tokens.isEmpty) return '';
    final sorted = rule.tokens.toSet().toList()
      ..sort((a, b) {
        final byCount = counts[a]!.compareTo(counts[b]!);
        if (byCount != 0) return byCount;
        final byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });
    return sorted.first;
  }

  final network = StringBuffer();
  for (final rule in rules.networkRules) {
    network.writeln(
      [
        rule.allow ? 'allow' : 'block',
        rule.host ?? '',
        indexToken(rule),
        rule.host == null ? rule.regex : '',
        rule.types?.join(',') ?? '',
        rule.party ?? '',
        rule.domains.join('|'),
        rule.matchCase ? 'c' : '',
      ].join('\t'),
    );
  }
  final cosmetic = StringBuffer();
  for (final h in rules.hideRules) {
    cosmetic.writeln('hide\t${h.domains.join('|')}\t${h.selector}');
  }
  for (final host in rules.noHideHosts) {
    cosmetic.writeln('nohide\t$host\t');
  }
  for (final host in rules.noGenericHideHosts) {
    cosmetic.writeln('nogeneric\t$host\t');
  }
  return (network: network.toString(), cosmetic: cosmetic.toString());
}

/// One `WKContentRuleList` as the file iOS compiles: a rule a line.
String webKitListJson(List<Map<String, Object?>> list) => '[\n${list.map(jsonEncode).join(',\n')}\n]\n';

/// [androidFiles] as the Android matcher reads them: each with the format's
/// header line, [about] (comment lines of where the rules come from), and
/// the names of the columns.
({String network, String cosmetic}) androidFileTexts(RuleSet rules, {required String about}) {
  final files = androidFiles(rules);
  return (
    network:
        '# Tabhand 広告ブロック, network rules (format 1; see ../README.md)\n$about\n'
        '# action\thost\ttoken\tregex\ttypes\tparty\tdomains\tflags\n${files.network}',
    cosmetic:
        '# Tabhand 広告ブロック, cosmetic rules (format 1; see ../README.md)\n$about\n'
        '# kind\tdomains\tselector\n${files.cosmetic}',
  );
}
