# Kioku(記憶)

Anki 互換の iOS 単語帳アプリです。本家 Anki の Rust コア(rslib 26.08.1)をそのまま組み込み、画面だけを SwiftUI で作り直しています。
スケジューリング(FSRS-6 / SM-2)、`.apkg` の取り込み、カードテンプレートの描画、統計は本家と同じコードで動きます。

- 白ベースのモノクロ UI
- リール風の学習画面(タップで答え、上スワイプ=普通、左スワイプ=もう一度)
- 周回モード(章を全問正解するまで回す。本番の復習予定には影響しない)
- 章分け(フラットなデッキを N 枚ずつサブデッキに分割)
- 綴り入力(`{{type:...}}` カード)対応
- 統計(今日・将来の期限・学習数・内訳・定着率・間隔・難易度・ボタン・時間帯)

## インストール

[Releases](../../releases) から `Kioku.ipa` をダウンロードします。未署名なので、自分の Apple ID で署名して入れます。

### LiveContainer の場合(推奨)

1. iPhone で `Kioku.ipa` をダウンロード(Safari で Release ページを開く → ipa をタップ → ダウンロード)
2. ファイル App で `Kioku.ipa` を長押し → 共有 → **LiveContainer** を選ぶ
3. LiveContainer の一覧に Kioku が出るので起動する
4. 起動しないときは LiveContainer 側で「Import Certificate from AltStore」をやり直す(証明書は 7 日で切れます)
5. ファイル選択で固まる場合は、LiveContainer のアプリ設定で **Fix File Picker** を ON にする

### AltStore / Sideloadly の場合

PC の AltServer / Sideloadly に ipa をドラッグして Apple ID で署名します。無料 Apple ID は 7 日ごとに更新が要ります。

## 使い方

### デッキを入れる

3 通りあります。どれでも結果は同じです。

1. **共有シート**: AnkiWeb などから `.apkg` を iPhone に保存し、ファイル App で共有 → **LiveContainer** → Kioku を選ぶ
2. **取り込みボタン**: Kioku 右上の取り込みボタンからファイルを選ぶ(LiveContainer で「開く」が効かないときは LiveContainer の Kioku 設定で **Fix File Picker** を ON)
3. **Documents に置く(いちばん確実)**: ファイル App で `.apkg` を Kioku の Documents フォルダに置き、Kioku を開く(または一覧を引き下げて更新)と「Documents に見つかったパッケージ」として出るので「取り込む」を押す。
   LiveContainer の場合の場所: ファイル App → このiPhone内 → **LiveContainer → Data → Application → (Kioku の UUID) → Documents**。UUID は Kioku の設定画面「取り込みの記録」に表示されるパスで確認できます。取り込み済みのファイルは `Documents/imported/` に移動します。

取り込み後、追加/更新/重複の枚数が出ます。同じファイルを再度入れても二重にはなりません(ノートの GUID で判定)。
失敗したときは設定画面の「取り込みの記録」に理由が残ります。

### 学習する

デッキをタップ →「学習を始める」。

| 操作 | 意味 |
|---|---|
| カードをタップ / 上スワイプ | 答えを表示 |
| 答え表示中に上スワイプ | 普通(Good) |
| 答え表示中に左スワイプ | もう一度(Again) |
| 下のボタン | もう一度 / 難しい / 普通 / 簡単(次回までの間隔つき) |
| 右上 ↶ | 直前の回答を取り消す(学習画面内) |

デッキ一覧右上の時計アイコンは「取り消す / やり直す」のメニューです。取り込みも取り消せる(=デッキが消える)ので確認が出ます。消してしまった場合は「やり直す」か、`Documents/imported/` のファイルを `Documents` に戻して再取り込みしてください。
| 右上 … | 音声再生・フラグ・埋める・保留・カード情報・新規に戻す |

綴り入力カード(`{{type:}}`)は入力欄が出ます。入力して Enter か、カードをタップすると本家と同じ差分表示になります。

### 周回する(本番に影響しない反復)

デッキ画面 →「この範囲を周回する」。範囲内のカードを、全部「普通」以上を押すまで繰り返します。
「もう一度」を押すと 1 分後にまた出ます。周回の結果は本番のスケジュールには記録されません。
終わると裏で作った一時デッキは自動で消えます。

### 章に分ける

サブデッキを持たないデッキで「章に分ける」→ 1 章の枚数を決めて実行。ノートの追加順(単語帳の並び)で `デッキ名::01`, `::02` … に振り分けます。
章ごとに周回したいときに使います。

### 今日だけ新規を増やす

デッキ画面の「今日だけ」で新規カードを追加できます(本家の「Custom Study → Increase today's new card limit」と同じ)。

### 統計

左上のグラフアイコン(全体)またはデッキ画面の「このデッキの統計」。期間は 1 か月 / 3 か月 / 1 年 / 全部。

## データの場所とバックアップ

コレクションは `Application Support/Kioku/default/` に `collection.anki2`(SQLite)、`collection.media/`、`backups/` として保存されます。
起動時に本家と同じ間隔で自動バックアップ、設定画面から手動バックアップもできます。
LiveContainer ではファイル App → LiveContainer → `Data/Application/<UUID>/Library/Application Support/Kioku/` から見えます。

## 制限(現時点)

- AnkiWeb との同期はありません(AnkiWeb の規約で承認クライアント以外は不可)。デッキの受け渡しは `.apkg` で行います
- ノートの追加・編集、ブラウザ、デッキオプション画面は未実装(次の版)
- MathJax(`\(...\)`)は未同梱。LaTeX は media に画像があれば表示されます(本家モバイル版と同じ)
- 通知・ウィジェットは LiveContainer では動かないため未対応

## ビルド

Windows / Linux からでも GitHub Actions(macOS ランナー)だけで ipa が作れます。

```
anki/                 本家 Anki(サブモジュール、tag 26.08.1)
bridge/               Rust → C の橋渡し(関数 5 つ)。staticlib
tools/dispatch-gen/   rslib の RPC 番号表から AnkiRPC.swift を生成
scripts/              build-xcframework.sh / generate-protos.sh / package.sh
app/                  SwiftUI アプリ(xcodegen の project.yml)
.github/workflows/    core をビルド → protobuf 生成 → シミュレータでテスト → 未署名 ipa → Release
```

手動で回すときは Actions の **Build** を `workflow_dispatch` し、`release_tag` に `v0.x.y` を入れると Release が作られます。
`v*` タグの push でも同じです。Rust コアはキャッシュされるので、2 回目以降はアプリ部分だけのビルドになります。

## ライセンス

AGPL-3.0-or-later。[ankitects/anki](https://github.com/ankitects/anki)(AGPL-3.0)を含みます。
設計は [antigluten/amgi](https://github.com/antigluten/amgi) を参考にしました。
