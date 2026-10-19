# tabhand-ad-lists

Tabhand（AI のエージェントが入ったモバイルのブラウザ）の広告ブロックが Android で使う規則の、元のリストと変換のスクリプト。Android の規則には AdGuard Japanese filter（GPLv3）から変換したものが入るので、GPLv3 の対応ソース（第 6 条）としてここに置く。

English follows the Japanese.

## 版

| リスト / List | 版 / Version | 取ってきた日 / Fetched (UTC) |
|---|---|---|
| AdGuard Japanese filter | 2.0.77.64 | 2026-10-18 |
| EasyList | 202610182336 | 2026-10-18 |

Tabhand の Android の規則のファイル（`network.tsv`・`cosmetic.tsv`）の見出しの行（`# AdGuard Japanese filter <版> (GPL-3.0)`）に、作るのに使った版が書いてある。Tabhand がリストを入れ替えるたびに、ここも入れ替える。前の版の元のリストは、このリポジトリの履歴にある（コミットのメッセージに版が書いてある）。

## 中身

| ファイル | 中身 |
|---|---|
| `tool/ad_block/sources/easylist.txt` | EasyList（`https://easylist.to/easylist/easylist.txt`）を取ってきたもの。手を入れていない |
| `tool/ad_block/sources/adguard_japanese.txt` | AdGuard Japanese filter（`https://filters.adtidy.org/extension/chromium/filters/7.txt`）を取ってきたもの。手を入れていない |
| `tool/ad_block/sources/fetched_on.json` | それぞれを取ってきた日（UTC） |
| `tool/ad_block/build_ad_lists.dart` | 流すスクリプト |
| `tool/ad_block/ad_lists.dart` | リストの一覧（元・ライセンス・使う OS）と、出力のファイルの組み立て |
| `lib/ad_block/ad_list_converter.dart` | 変換（Tabhand のアプリも同じものを使う）。Adblock Plus / AdGuard の書き方から、Android の TSV と iOS の `WKContentRuleList` の JSON に |

Android の規則は EasyList と AdGuard Japanese filter の両方から作るので、両方を置いている。iOS の規則は EasyList だけから作り、AdGuard Japanese filter は入らない。

変換で残すのは、通信の規則と、CSS のセレクタで隠す規則だけ。JavaScript で動く規則（scriptlet など）や、形にできない規則は捨てる。

## 作り直す

Dart SDK 3.12 以降で（Flutter は要らない）、このリポジトリのいちばん上で:

```sh
dart run tool/ad_block/build_ad_lists.dart
```

`assets/ad_block/` に次ができる。同じ元のリストからは、かならず同じものができる。

| ファイル | 中身 |
|---|---|
| `android/network.tsv` | Android の通信の規則。Tabhand の Android 版に入っているものとバイト単位で同じ |
| `android/cosmetic.tsv` | Android の見た目で隠す規則。同じくバイト単位で同じ |
| `ios/rules-N.json` | iOS の規則（EasyList だけ） |
| `ad_lists.json` | リストの版・取ってきた日、規則の数、捨てた規則の数（理由ごと） |

確かめるには、Tabhand の Android の APK の中の `assets/flutter_assets/assets/ad_block/android/*.tsv` と比べる（`shasum -a 256` など）。

元のリストを取り直してから作るなら `--fetch` を付ける（`tool/ad_block/sources/` を書き換える）。

## ライセンス

このリポジトリは GNU General Public License version 3（`LICENSE`）で配る。

- AdGuard Japanese filter: Copyright AdGuard (https://adguard.com/) and the contributors of https://github.com/AdguardTeam/AdguardFilters 。GPLv3。
- EasyList: Copyright The EasyList authors (https://easylist.to/)。GPLv3 以降か CC BY-SA 3.0 以降の選択（https://easylist.to/pages/licence.html）。ここでは GPLv3 で配る。
- 変換のスクリプト（`tool/ad_block/*.dart` と `lib/ad_block/ad_list_converter.dart`）: Copyright obutora。GPLv3。

## English

The source lists and converter scripts of the rules Tabhand (a mobile browser with a built-in AI agent) uses for ad blocking on Android. Those rules include rules converted from AdGuard Japanese filter (GPLv3), so this repository is their Corresponding Source under GPLv3 section 6.

- **Versions**: see the table under 「版」 above. The header lines of Tabhand's Android rule files name the list versions they were made from. This repository is updated whenever Tabhand replaces its lists; earlier versions are in the history (each commit message names the versions).
- **Contents**: `tool/ad_block/sources/` holds EasyList and AdGuard Japanese filter as fetched, unmodified, with the fetch dates in `fetched_on.json`. The Android rules are made from both lists; the iOS rules from EasyList only. `tool/ad_block/*.dart` and `lib/ad_block/ad_list_converter.dart` are the converter. It keeps network rules and plain CSS hiding rules and drops rules that need JavaScript or that the output format cannot express.
- **Rebuilding**: with Dart SDK 3.12 or later (no Flutter needed), run `dart run tool/ad_block/build_ad_lists.dart` at the top of this repository. It writes `assets/ad_block/`; `android/network.tsv` and `android/cosmetic.tsv` are byte-for-byte the files in Tabhand's Android app (`assets/flutter_assets/assets/ad_block/android/` in the APK). Add `--fetch` to fetch the lists anew first.
- **License**: GNU General Public License version 3 (`LICENSE`). AdGuard Japanese filter is GPLv3 (AdGuard and the contributors of AdguardFilters). EasyList is GPLv3 or later, or CC BY-SA 3.0 or later, at the user's option (The EasyList authors); it is distributed here under GPLv3. The converter scripts are Copyright obutora, GPLv3.
