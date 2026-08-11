# 導入ガイド

> English version: [getting-started.md](getting-started.md)

リポジトリの配置から、ユーザースコープでのインストール、カタログエージェントへの最初の委譲、並列ワーカーのファンアウトまでを案内します。
リファレンス（カタログ全表、フックの詳細、設定）は [README](../README.md)（英語）にあります。

> **Status: Experimental.** オーケストレーションは複数の Claude Code エージェントを起動するため、トークンを大きく消費し得ます。小さく始めて使用量を確認してください。

## このガイドで得られる状態

- ccorch を一度インストールするだけで、model 固定の9エージェント型、強制フック、`/ccor` と `/ccor-parallel` スキルが全リポジトリで使える
- 最初の委譲を実行し、その起動が台帳（ledger）に記録されている
- 既定のサブエージェントと、tmux ペインが適する3条件とを使い分けられる

## 前提

- [Claude Code](https://code.claude.com/docs/en/overview) CLI
- `jq`（推奨。無いと v2 フックは何もしません）
- `git`（`/ccor-parallel` の worktree 分離は git リポジトリが前提です）
- `tmux` 1.8 以上（ペインモード `/ccor` のみ）
- 任意: [ghq](https://github.com/x-motemen/ghq)（後述のクローン配置を自動化）

## 手順1: リポジトリを配置する

オーケストレーションは、通常のセッションよりファイルシステムの広い範囲に触れます。
ペインモードは作業ディレクトリを対象リポジトリに固定したセッションを起動し、並列ワーカーは現在のリポジトリの worktree で作業します。
クローン配置が規則的だと、「このペインやワーカーはどのパスで動くのか」を調べる代わりに推測できます。

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
プラグインは `~/.claude/` 配下に一度だけインストールされ、エージェント、フック、スキルが開くすべてのリポジトリで有効になります。
本ガイドはこの状態を前提にします。

シェルから非対話でインストールする場合は次のとおりです。

```bash
claude plugin install ccorch@levnas-plugins --scope user
```

インストール結果に `Run /reload-plugins to activate` と表示されたら `/reload-plugins` を実行します（新しいセッションを開き直しても同じです）。
有効になったことは次の2点で確認できます。

- `/plugin list` に ccorch が表示される
- Claude に「what ccorch agent types are available?」と尋ねると、[README のカタログ表](../README.md#agent-catalog)にある9種の `ccorch:*` 型が列挙される

**チーム向けの補足**: 共有プロジェクトを開いた全員に ccorch を自動で有効化するには、プロジェクトの `.claude/settings.json` に次をコミットします（各メンバーはマーケットプレイス追加の1行だけ実行しておきます）。

```json
{
  "enabledPlugins": {
    "ccorch@levnas-plugins": true
  }
}
```

## 手順3: 最初の委譲を実行する

v2 の既定では特別なコマンドは要りません。
プラグインが入っていれば Claude Code はカタログ型を認識するので、普通の言葉で委譲を頼みます。

> ccorch:web-research を使って、X の現在のアプローチを出典付きで調査して。

このとき起きていることは次の3つです。

- リーフは frontmatter に固定された model と effort（この型なら sonnet の low）で動きます。メインセッションの高価なモデルを黙って継承しません。
- `agent_gate.sh` が並列上限（既定3）とモデルルーティングを強制します。
- 起動記録が `.claude/ccorch/ledger.jsonl` に追記されます。

初回実行後に台帳を確認します。

```bash
tail -1 .claude/ccorch/ledger.jsonl | jq .
```

形式の詳細は [ledger.md](ledger.md) にあります。
ファイルが無い場合は `jq` の有無を確認してください。
フックは fail-open 設計なので、`jq` が無いとブロックせず黙って何もしなくなります。

リーフはコストで選びます。
抽出とログ蒸留は haiku、調査と実装は sonnet、決定級の主張の反証は sonnet の high effort で動きます（[カタログ表](../README.md#agent-catalog)）。
リーフの出力が不十分なときは、同じプロンプトを1段上のモデルで再実行します（最大1回）。
リーフ自身には品質を判定させません。

## 手順4: 並列ワーカーをファンアウトする（任意）

ファイル所有権が重ならない実装タスクが複数あるときは、`/ccor-parallel` が worktree 分離されたワーカーへファンアウトし、統合専用の worktree でマージし（main には触れません）、後片付けまで行います。

```
/ccor-parallel <タスクごとのファイル所有権を明記したタスクリスト>
```

手順の全体とオーケストレータの4責務は [skills/ccor-parallel/SKILL.md](../skills/ccor-parallel/SKILL.md) にあります。

## ペインが適する3条件

サブエージェントで賄えない次の3条件のときだけ、`/ccor`（tmux ペインモード）を使います。

1. **別リポジトリへの書込**を伴う作業
2. 対象リポジトリの**権限とフックの強制層**を安全網として効かせたい作業
3. **リアルタイムの目視監督**が必要な作業

```
/ccor <タスクの説明>
```

## チューニング

既定値は保守的です。
初日に知る価値があるのは `CCORCH_MAX_PARALLEL`（既定 `3`）だけです。
同時に動くエージェントはそれぞれが1つの Claude Code インスタンスなので、控えめなホストでは `2` に下げます。
環境変数の全表は [README](../README.md#enforcement-hooks) にあります。

## ccmemo でループを閉じる

オーケストレーションされたセッションは、1つのコンテキストウィンドウに保持できる以上のことを発見します。
永続化がなければ、次のセッションはゼロから始まります。
同じマーケットプレイスの姉妹プラグイン [ccmemo](https://github.com/LevNas/ccmemo) がこの永続化を担い、カタログのうち2型は ccmemo に直接つながるように作られています。

- **`ccorch:knowledge-recorder`**：ccmemo の `/record-knowledge` 規約に沿ってナレッジエントリを起草します。ccmemo で scaffold した構成（`.claude/knowledge/`）があれば、オーケストレーションの1ウェーブを、そのままコミットできるエントリ群の下書きで締めくくれます。何を記録するかの判断は自分の手に残ります。
- **`ccorch:kb-integrator`**：10件以上の ccmemo エントリを読み、出典付きの統合を返します。エントリが増えても、設計前の「何をすでに知っているか」の確認が一問で済みます。

ccmemo は逆方向の記憶も与えます。
`/plan-task` は複数ウェーブの計画をセッションをまたいで保持するので、大きなオーケストレーションを1回のマラソンではなく、日をまたいで再開できるウェーブの列として実行できます。
`/recall-knowledge` を使えば、新しいセッションは再発見にトークンを費やす前に、過去のウェーブの学びを回収できます。

```
/plugin install ccmemo@levnas-plugins
```

ccmemo 側のセットアップは [ccmemo の導入ガイド（日本語）](https://github.com/LevNas/ccmemo/blob/main/docs/getting-started.ja.md) を参照してください。
