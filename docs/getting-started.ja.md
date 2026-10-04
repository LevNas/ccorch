# 導入ガイド

> English version: [getting-started.md](getting-started.md)

リポジトリの配置から、ユーザースコープでのインストール、最初の `/ccor` 実行までを案内します。
リファレンス（設定、安全策）は [README](../README.md)（英語）にあります。

> **Status: Experimental.** オーケストレーションは複数の Claude Code セッションを起動するため、トークンを大きく消費し得ます。小さく始めて使用量を確認してください。

ccorch の仕事は1つで、作業を**別々の tmux ペイン**に分けることです。
1つのセッションの内側での作業の振り分け（末端のエージェント、worktree を使った並列実行、エージェントの記録）は 0.5.0 から ccorch の対象外です。
移動先は [README の Moved to ccharness](../README.md#moved-to-ccharness-090) を参照してください。

## このガイドで得られる状態

- ccorch を一度インストールするだけで、`/ccor` スキルが全リポジトリで使える
- tmux ペインでの最初の `/ccor` 実行を終えている
- ペインが適する3条件を使い分けられる

## 前提

- [Claude Code](https://code.claude.com/docs/en/overview) CLI
- `tmux` 1.8 以上（必須。`/ccor` は tmux セッションの中で実行します）
- [auto モード](https://code.claude.com/docs/en/permission-modes)が使えること（ペインを確認なしで動かすため。使えないときの動きは「[設定](#設定)」を参照）
- 任意: [ghq](https://github.com/x-motemen/ghq)（後述のクローン配置を自動化）

## 手順1: リポジトリを配置する

ペインモードは、作業ディレクトリを対象リポジトリに固定したセッションを起動します。
クローン配置が規則的だと、「このペインはどのパスで動くのか」を調べる代わりに推測できます。
自分にも Main Brain にも分かりやすくなります。

そこで `~/src/<ホスト>/<オーナー>/<リポジトリ>` の配置を推奨します。
素の `git clone` で作れます。

```bash
git clone https://github.com/you/app ~/src/github.com/you/app
```

[ghq](https://github.com/x-motemen/ghq) はまさにこの配置を自動化するツールです。

```bash
git config --global ghq.root '~/src'
ghq get github.com/you/app        # ~/src/github.com/you/app にクローンされる
ghq list                          # 全リポジトリを1行ずつ列挙
```

ghq は任意で、ccorch は ghq に依存しません。

## 手順2: ユーザースコープでインストールする

任意の Claude Code セッションで実行します。

```
/plugin marketplace add LevNas/claudecode-plugins
/plugin install ccorch@levnas-plugins
```

スコープを聞かれたら **User** を選びます。
プラグインは `~/.claude/` 配下に一度だけインストールされ、スキルが開くすべてのリポジトリで有効になります。

シェルから非対話でインストールする場合は次のとおりです。

```bash
claude plugin install ccorch@levnas-plugins --scope user
```

インストール結果に `Run /reload-plugins to activate` と表示されたら `/reload-plugins` を実行します（新しいセッションを開き直しても同じです）。
`/plugin list` に ccorch が表示されれば有効です。

**チーム向けの補足**: 共有プロジェクトを開いた全員に ccorch を自動で有効化するには、プロジェクトの `.claude/settings.json` に次をコミットします（各メンバーはマーケットプレイス追加の1行だけ実行しておきます）。

```json
{
  "enabledPlugins": {
    "ccorch@levnas-plugins": true
  }
}
```

## 手順3: 最初のペイン実行

tmux セッションを開始（または接続）し、その中で Claude Code を起動して実行します。

```
/ccor <タスクの説明>
```

セッションの横に Main Brain のペインが開き、タスクを分解して Child ペインへ委譲します。
自分のセッションは空いたままで、Main Brain が完了を知らせると通知が届きます。
結果は `/tmp/ccorch/<session_id>/` から読み取られます。

ペインを使うのは次の3条件のときだけです。

1. **別リポジトリへの書込**を伴う作業
2. 対象リポジトリの**権限とフックの層**の下で動かす必要がある作業
3. **リアルタイムの目視監督**が必要な作業

それ以外は1つのセッションで行うほうが安く済みます。

## 設定

調整できるのは [README](../README.md#configuration) の `CCORCH_*` 環境変数です。
初日に知る価値があるのは `CCORCH_MAX_CHILDREN_D1`（既定 `3`）です。
ペインはそれぞれが1つの Claude Code インスタンスなので、控えめなホストでは値を下げます。

ペイン数と子の数の上限は、ペインが起動する前にラッパーが強制します。
上限を超えるペインは実行されず、理由つきの `status: refused` を返します。

ペインは権限バイパスではなく、auto モード（`--permission-mode auto`）で動きます。
auto モードの分類器が操作をブロックすると、そのペインが人の判断を待つことがあります。
そのときはペインを確認し、承認するか、指示を出し直してください。
ペインのセッションで auto モードが使えないとき（auto モードに対応していないモデル、`disableAutoMode` の設定で auto モードを外している、Anthropic 側で一時的に止めている場合）は、Claude Code がペインを Manual モードで起動し、ほとんどの操作の前に確認を求めます。
auto モードが有効なときだけ、ペインの状態行に `auto mode on` と表示されます。
確認を待ったまま `CCORCH_TIMEOUT`（既定 600 秒）が過ぎたペインは止められます。
起動の関門と deny ルールは、どのモードでも効きます。
破壊的なコマンドの通常の形は deny ルールで拒否され、`git push` は Child と Grandchild のペインで拒否されます。
これらの Bash ルールは通常のコマンド形だけを捉えるもので、セキュリティ境界ではありません。

## ccmemo でループを閉じる

ペインでの実行は、1つのコンテキストウィンドウに保持できる以上のことを発見します。
永続化がなければ、次のセッションはゼロから始まります。
同じマーケットプレイスの姉妹プラグイン [ccmemo](https://github.com/LevNas/ccmemo) がこの永続化を担います。

- `/record-knowledge`：実行で見つかったことを記録します。ccmemo で scaffold した構成（`.claude/knowledge/`）があれば、そこにエントリが置かれます。何を記録するかの判断は自分の手に残ります。
- `/plan-task`：複数段階の計画をセッションをまたいで保持します。大きなタスクを、1回で走り切るのではなく、日をまたいで再開できる段階の列として進められます。
- `/recall-knowledge`：新しいセッションが、再発見にトークンを費やす前に、過去の実行の学びを回収できます。

```
/plugin install ccmemo@levnas-plugins
```

ccmemo 側のセットアップは [ccmemo の導入ガイド（日本語）](https://github.com/LevNas/ccmemo/blob/main/docs/getting-started.ja.md) を参照してください。
