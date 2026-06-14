# gaipack-demo-creator — Claude Edition

お客様向けデモアプリを、Claude Code のみのマルチエージェント構成で自動生成するハーネスです。

お客様名とシステム概要を入力するだけで、企業調査→仕様書→デザイン→実装→QA評価までを一貫して実行します。各エージェントは独立した `claude -p` 呼び出し（独立コンテキスト）として動作し、レビュー系エージェントは生成とは別セッションで実行することで自己レビューバイアスを軽減します。

---

## 目次

1. [アーキテクチャ](#アーキテクチャ)
2. [前提条件](#前提条件)
3. [セットアップ手順](#セットアップ手順)
4. [使い方](#使い方)
5. [実行フロー詳細](#実行フロー詳細)
6. [生成されるファイル](#生成されるファイル)
7. [ディレクトリ構成](#ディレクトリ構成)
8. [個別エージェントの実行](#個別エージェントの実行)
9. [カスタマイズ](#カスタマイズ)
10. [トラブルシューティング](#トラブルシューティング)

---

## アーキテクチャ

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Claude Code (Orchestrator)                        │
│                         run.sh を実行                                 │
├──────────┬──────────┬──────────┬──────────┬──────────┬────────────────┤
│ Agent 0  │ Agent 1  │ Agent 2  │ Agent 3  │ Agent 4  │ Agent 5        │
│ DocReader│Researcher│ Planner  │ Designer │ Builder  │ Evaluator      │
│(Pre-step)│          │          │          │          │                │
│          │          │          │          │          │                │
│ Claude   │ Claude   │ Claude   │ Claude   │ Claude   │ Claude         │
│ Code     │ Code     │ Code     │ Code     │ Code     │ Code           │
├──────────┼──────────┼──────────┼──────────┼──────────┼────────────────┤
│顧客資料  │ Web検索  │ 仕様書   │ デザイン │ 実装     │ レビュー       │
│読み込み  │ 企業調査 │ 生成     │ 設計     │ テスト   │ QA評価         │
│(optional)│          │          │          │          │                │
└────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬───────────┘
     ↓          ↓          ↓          ↓          ↓          ↓
 input_docs.md customer.md DEMO_SPEC.md DESIGN.md demo-app/ QA_REPORT.md
 (docs/ があれば)
```

各エージェントは独立した `claude -p` 呼び出し（独立コンテキスト）で動作し、ファイルのみで情報を受け渡します（context reset + structured handoff）。レビュー系エージェント（2.5 / 3.5 / 5）は生成エージェントとは別セッションで起動し、実装の文脈を引きずらない第三者視点でレビューすることで、同一モデルでも自己レビューバイアスを軽減します。

| Agent | 実行LLM | 役割 | 主な使用ツール |
|-------|---------|------|----------------|
| 0. Document Reader | Claude Code | 顧客受領資料の読み込み（optional） | Read / Bash（PDF/Docx/Xlsx等の多形式対応） |
| 1. Researcher | Claude Code | Web調査・企業情報収集 | WebSearch / WebFetch |
| 2. Planner | Claude Code | 仕様書生成 | Write / Read |
| 2.5 Spec Review | Claude Code | 仕様書レビュー（別セッション） | Write / Read |
| 3. Designer | Claude Code | デザイン設計 | frontend-design スキル連携 |
| 3.5 Design Review | Claude Code | デザインレビュー（別セッション） | Write / Read |
| 4. Builder | Claude Code | 実装+テスト | Edit / Write / Read / Bash |
| 5. Evaluator | Claude Code | QA評価（別セッション） | Read / Bash / Write |

---

## 前提条件

- **Node.js** 18 以上
- **Claude Code** がインストール済み（Max Plan 等のサブスクリプション）
- WebSearch / WebFetch が有効な Claude Code 環境（Agent 1 の企業調査で使用）

---

## セットアップ手順

### Step 1: ハーネスのインストール

```bash
# zipを展開
unzip gaipack-demo-creator.zip

# プロジェクトディレクトリにコピー（or そのまま使用）
cd gaipack-demo-creator

# run.sh に実行権限を付与
chmod +x run.sh
```

### Step 2: Claude Code の動作確認

全工程を Claude Code で実行します。追加の CLI や API Key 設定は不要です。

```bash
# Claude Code が利用可能か確認
which claude && echo "✅ Claude Code OK" || echo "❌ Claude Code not found"

# 簡単な動作確認
claude -p "こんにちは。あなたは何のモデルですか？"
```

レスポンスが返ってくればセットアップ完了です。

> **Note:** Agent 1（Researcher）は WebSearch / WebFetch ツールで企業情報を調査します。
> 利用環境で Web ツールが有効になっていることを確認してください。

---

## 使い方

起動方法は2通りあります。どちらも同じパイプライン・同じ出力先（`../demo/`）です。

### 方法A: Claude Code の skill として実行（推奨）

`gaipack-demo-creator/` ディレクトリで Claude Code を開き、skill を呼び出します。

```
/gaipack-demo-creator お客様名: 株式会社サンプル  求めているシステム: 在庫管理ダッシュボード
```

オーケストレーター skill が各ステージを **サブエージェント（Agent ツール＝独立コンテキスト）** として
順に起動します。生成エージェントとレビューエージェントが別サブエージェントに分離されるため、
「生成とレビューの分離」がネイティブに担保されます。`claude -p` の再帰起動や追加認証は不要です。

> skill が一覧に出ない場合は、`.claude/skills/gaipack-demo-creator/SKILL.md` を含むディレクトリ
> （ハーネス本体）で Claude Code を起動しているか確認してください。

### 方法B: シェルスクリプトとして実行（CLI版）

```bash
# プロジェクトルート（例: 202605-toyota-system/）配下に gaipack-demo-creator を解凍した状態で
cd /path/to/202605-toyota-system/gaipack-demo-creator

# テキストで直接入力
./run.sh 'お客様名: 株式会社サンプル  求めているシステム: 在庫管理ダッシュボード'
```

各ステージを `claude -p` のサブプロセスとして起動します。CI やターミナルから回したい場合に使います。

いずれの方法でも、プロジェクトルート（`gaipack-demo-creator/` の親ディレクトリ）に `demo/` ディレクトリを**新規作成**し、その配下に成果物を出力します。事前に `demo/` を準備する必要はありません。

### 既存の demo/ がある状態で再実行する場合

上書き事故を防ぐため、ハーネスは既存の `demo/` がある状態では実行を停止します。以下のいずれかの対応をしてから再実行してください。

```bash
# 前回の成果物を破棄してやり直す場合
rm -rf ../demo

# 前回の成果物を残しておきたい場合（タイムスタンプ付きで退避）
mv ../demo ../demo.$(date +%Y%m%d_%H%M%S)
```

### 入力ファイルを使う方法（推奨）

情報が多い場合は Markdown ファイルに書いて渡せます。

```bash
# input.md を作成（gaipack-demo-creator/ 内でも、プロジェクトルートでも可）
cat > input.md << 'EOF'
お客様名: 株式会社サンプルコーポレーション
WebサイトURL: https://www.example.co.jp
求めているシステム: 営業チーム向けのリアルタイム売上ダッシュボード

補足情報:
- 現在はExcelで月次レポートを手動作成している
- 営業マネージャー5名が主な利用者
- SalesforceにCRMデータがある
- 来月の役員会議でデモを見せたい
EOF

# input.md を渡して実行
./run.sh input.md
```

### 入力に含めると精度が上がる情報

必須は「お客様名」と「求めているシステム」のみです。以下はあれば精度が上がりますが、なくても公開情報から自動推察します。

- WebサイトURL
- 業界・業種
- 現在のペインポイント
- 想定ユーザー（現場担当者 or 管理職 or 経営層）
- 利用デバイス（PC / タブレット）
- 連携先の既存システム（Salesforce, SAP 等）
- 意思決定者の関心事（UX重視 / 技術重視 / コスト重視）
- 商談フェーズ（初回 / コンペ）

### 顧客から受領したドキュメントを使う場合（推奨）

RFP、業務フロー図、ブランドガイド等のドキュメントを受領している場合は、**プロジェクトルート直下の `docs/` ディレクトリ**に配置してください。実行前に自動で読み込み、最優先の一次情報として扱います。

```bash
# プロジェクトルート（gaipack-demo-creator/ の親）に docs/ を作成
cd /path/to/202605-toyota-system
mkdir -p docs
cp ~/Downloads/RFP_v2.pdf docs/
cp ~/Downloads/業務フロー図.xlsx docs/
cp ~/Downloads/brand_guide.pdf docs/

# あとは通常通り実行するだけ
cd gaipack-demo-creator
./run.sh input.md
```

対応形式: **PDF / DOCX / XLSX / PPTX / MD / TXT / PNG / JPG**

動作:
- `../docs/` が存在しない、または空の場合は読み込みステップを自動でスキップします
- `../docs/` にファイルがある場合は Agent 0（Document Reader）が実行され、`../demo/memory/input_docs.md` に要約が出力されます
- 要約された情報は Agent 1（Researcher）と Agent 2（Planner）で Web 検索結果よりも**優先して採用**されます
- 各情報には出典ファイル名が付記されるので、商談で追跡・確認できます

**何をdocs/に入れるべきか**: 顧客から受領した一次資料（RFP、提案依頼書、業務フロー図、ブランドガイド、現行システムのスクリーンショット等）。あなたが要約した議事録より、顧客の原文のほうが推察ノイズが減ります。

### gaipack 標準アーキ・技術スタックを反映する場合

gaipack の標準アーキテクチャや技術スタック、ガイドラインを **プロジェクトルート直下の `references/` ディレクトリ** に MD / TXT で配置すると、Agent 2（Planner）と Agent 4（Builder）のプロンプトに自動で含まれます。

```bash
cd /path/to/202605-toyota-system
mkdir -p references
cp gaipack-architecture.md references/
cp gaipack-tech-stack.md references/
```

動作:
- `../references/` が存在しない、または MD/TXT ファイルがない場合は読み込みステップを自動でスキップします
- 仕様書（DEMO_SPEC.md）も実装（demo-app/）も、references の前提に沿って生成されます

---

## 実行フロー詳細

skill（`/gaipack-demo-creator`）または `./run.sh` を実行すると、以下のステップが自動で順番に実行されます。
skill版では各ステップがサブエージェント、CLI版では各ステップが `claude -p` サブプロセスとして起動します。

```
Step 0   [Claude Code]  Document Reader  顧客受領資料を読み込み要約（docs/ がある場合のみ）
  ↓ input_docs.md
Step 1   [Claude Code]  Researcher    企業の公開情報を WebSearch で調査
  ↓ customer.md
Step 2   [Claude Code]  Planner      5セクション構成のデモ仕様書を生成
  ↓ DEMO_SPEC.md
Step 2.5 [Claude Code]  Spec Review   別セッションで仕様書をレビュー
  ↓ 指摘あり？ → [Claude Code] 修正 → [Claude Code] 再レビュー（最大2ラウンド）
Step 3   [Claude Code]  Designer     コーポレートカラーを基調にデザイン設計
  ↓ DESIGN.md
Step 3.5 [Claude Code]  Design Review 別セッションでデザインをレビュー
  ↓ 指摘あり？ → [Claude Code] 修正 → [Claude Code] 再レビュー（最大2ラウンド）
Step 4   [Claude Code]  Builder      React + TypeScript でデモアプリを実装
  ↓ demo-app/
Step 5   [Claude Code]  Evaluator     別セッションで仕様書と照合し4基準×10点で厳格評価
  ↓ QA_REPORT.md                    不合格？ → [Claude Code] 修正 → [Claude Code] 再評価（最大3ラウンド）
```

仕様書は以下の 5 セクションで構成されます。入力で足りない情報は公開情報から推察し、推察根拠を明記します。

1. **業務コンテキスト** — ペインポイント、想定ユーザー、利用環境、導入後ゴール
2. **スコープと優先度** — 必須機能、最も見たい画面、除外範囲
3. **データと入出力** — 扱うデータ、連携先システム、モックデータ方針
4. **非機能要件** — ブランドカラー、認証方式、参考サービスと差別化
5. **判断基準** — 意思決定者、判断ポイント、デモシナリオ、成功基準

---

## 生成されるファイル

実行が完了すると、プロジェクトルートの `demo/` 配下に以下のファイルが生成されます（`gaipack-demo-creator/` から見ると `../demo/` 配下）。

| ファイル | 生成元 | 内容 |
|----------|--------|------|
| `demo/memory/input_docs.md` | Claude Code（../docs/ がある場合のみ） | 顧客受領ドキュメントの要約 |
| `demo/memory/customer.md` | Claude Code | お客様情報（コーポレートカラー、業界情報、DX方針） |
| `demo/spec/DEMO_SPEC.md` | Claude Code → 別セッションでレビュー済 | デモ仕様書（5セクション構成） |
| `demo/spec/SPEC_REVIEW.md` | Claude Code | 仕様書へのレビュー結果 |
| `demo/spec/DESIGN.md` | Claude Code → 別セッションでレビュー済 | デザインドキュメント（カラー、タイポグラフィ、コンポーネント） |
| `demo/spec/DESIGN_REVIEW.md` | Claude Code | デザインへのレビュー結果 |
| `demo/demo-app/` | Claude Code | 動作するデモアプリケーション（React + TypeScript） |
| `demo/spec/QA_REPORT.md` | Claude Code | QA評価レポート（4基準×10点のスコア付き） |

### デモアプリの起動方法

```bash
cd ../demo/demo-app   # gaipack-demo-creator/ から見た場合
npm install
npm run dev
```

ブラウザで `http://localhost:5173` を開くとデモが確認できます。

---

## ディレクトリ構成

gaipack-demo-creator はプロジェクトルート（例: `202605-toyota-system/`）配下に解凍して使います。
顧客受領資料（`docs/`）と gaipack 標準参照（`references/`）はプロジェクトルートに置き、ハーネスがそれらを参照して `demo/` 配下に成果物を出力します。

```
202605-toyota-system/              ← プロジェクトルート
├── docs/                          ← 【optional】顧客から受領したドキュメント
│   ├── RFP_v2.pdf                 #  対応形式: PDF/DOCX/XLSX/PPTX/MD/TXT/PNG/JPG
│   ├── 業務フロー図.xlsx
│   └── brand_guide.pdf
├── references/                    ← 【optional】gaipack 標準アーキ・技術スタック等
│   ├── architecture.md            #  対応形式: MD/TXT
│   └── tech-stack.md
├── proposal/                      ← 提案書ドキュメント（ハーネス対象外）
├── demo/                          ← 自動生成される（ハーネス出力先）
│   ├── memory/
│   │   ├── input_docs.md          # docs/ がある場合のみ生成
│   │   └── customer.md
│   ├── spec/
│   │   ├── DEMO_SPEC.md
│   │   ├── SPEC_REVIEW.md
│   │   ├── DESIGN.md
│   │   ├── DESIGN_REVIEW.md
│   │   └── QA_REPORT.md
│   └── demo-app/                  # 動作するデモアプリ (React + TypeScript)
└── gaipack-demo-creator/          ← ZIP解凍したハーネス本体
    ├── README.md                  ← この文書
    ├── CLAUDE.md                  ← Claude Code が読み込むハーネス定義
    ├── run.sh                     ← オーケストレーター（CLI版）
    └── .claude/
        ├── skills/
        │   ├── gaipack-demo-creator/SKILL.md # オーケストレーター（skill版・推奨）
        │   ├── 00-document-reader/SKILL.md # Agent 0: 顧客ドキュメント読み込み（Claude Code）
        │   ├── 01-researcher/SKILL.md      # Agent 1: Web調査（Claude Code）
        │   ├── 02-planner/SKILL.md         # Agent 2: 仕様書生成（Claude Code）
        │   ├── 03-designer/SKILL.md        # Agent 3: デザイン設計（Claude Code）
        │   ├── 04-builder/SKILL.md         # Agent 4: 実装+テスト（Claude Code）
        │   └── 05-evaluator/SKILL.md       # Agent 5: QA評価（Claude Code）
        └── rules/
            └── architecture.md             # コーディング規約・制約
```

### references/ の使い方
gaipack の標準アーキテクチャ・技術スタック・ガイドラインを `references/` に配置すると、Agent 2（Planner）と Agent 4（Builder）のプロンプトに自動で含まれます。仕様書と実装の両方が gaipack の前提に沿うようになります。MD / TXT のみ対応。

---

## 個別エージェントの実行

特定のエージェントだけを手動で実行したい場合は、以下のように `claude` を直接呼び出せます（`gaipack-demo-creator/` ディレクトリで実行する想定）。

### Agent 1 (Researcher) だけ実行

```bash
claude -p "$(cat .claude/skills/01-researcher/SKILL.md)

以下のお客様について調査し、結果を ../demo/memory/customer.md に書き出してください：
お客様名: 株式会社サンプル
求めているシステム: 在庫管理ダッシュボード" --allowedTools "WebSearch,WebFetch,Write,Read"
```

### Agent 2 (Planner) だけ実行

```bash
claude -p "$(cat .claude/skills/02-planner/SKILL.md)

$(cat ../demo/memory/customer.md)" --allowedTools "Edit,Write,Read"
```

### Agent 5 (Evaluator) だけ実行

```bash
claude -p "$(cat .claude/skills/05-evaluator/SKILL.md)

$(cat ../demo/spec/DEMO_SPEC.md)

../demo/demo-app/ を読み、../demo/spec/QA_REPORT.md を作成してください。" --allowedTools "Read,Bash,Write"
```

---

## カスタマイズ

### 仕様書のテンプレートを変更したい

`.claude/skills/02-planner/SKILL.md` を編集してください。5 セクションの構成や各項目を自由に追加・変更できます。

### デザインの方針を変更したい

`.claude/skills/03-designer/SKILL.md` を編集してください。デフォルトでは Claude Code の frontend-design スキルに準拠しますが、独自のデザインガイドラインに差し替えることも可能です。

### QA 評価基準を変更したい

`.claude/skills/05-evaluator/SKILL.md` を編集してください。4 つの評価基準（仕様適合性、デザイン品質、デモ適性、技術品質）の合格ラインやチェック項目を調整できます。

### 技術スタックを変更したい

`.claude/skills/04-builder/SKILL.md` のプロジェクト初期化コマンドと `.claude/rules/architecture.md` を編集してください。デフォルトは React (Vite) + TypeScript + Tailwind CSS です。

---

## トラブルシューティング

### 「既存の demo/ ディレクトリが見つかりました」というエラーで止まる

上書き事故を防ぐため、ハーネスは既存の `demo/` には書き込みません。以下のいずれかで対応してください。

```bash
# 前回の成果物が不要な場合（破棄）
rm -rf ../demo

# 前回の成果物を残したい場合（タイムスタンプ付きで退避）
mv ../demo ../demo.$(date +%Y%m%d_%H%M%S)

# 再実行
./run.sh input.md
```

### `claude: command not found`

Claude Code がインストールされているか確認してください。
インストール手順: https://docs.anthropic.com/en/docs/claude-code

### customer.md が空になる

Agent 1（Researcher）の Web 調査が機能していない可能性があります。
利用環境で WebSearch / WebFetch ツールが有効か確認し、以下で直接テストしてください。

```bash
claude -p "株式会社トヨタ自動車の公式サイトを検索して、コーポレートカラーを教えてください" --allowedTools "WebSearch,WebFetch"
```

エラーが出る場合は `/tmp/agent1_err.log` を確認してください。

```bash
cat /tmp/agent1_err.log
```

### レビュー結果（SPEC_REVIEW.md / DESIGN_REVIEW.md / QA_REPORT.md）が生成されない

レビュー系エージェントの実行ログを確認してください。

```bash
cat /tmp/agent2_5_round1.log   # Spec Review
cat /tmp/agent3_5_round1.log   # Design Review
cat /tmp/agent5_round1.log     # Evaluator
```

### demo-app/ が生成されない

Claude Code の実行でエラーが出ている可能性があります。`/tmp/agent4_err.log` を確認してください。

```bash
cat /tmp/agent4_err.log
```

---

## 料金目安

全工程を Claude Code で実行するため、追加の従量課金 API はありません。

| CLI | 用途 | コスト |
|-----|------|--------|
| Claude Code | 企業調査・仕様書生成・デザイン・実装・レビュー・QA評価（全工程） | Max Plan 等のサブスクリプションに含まれる |

---

## 参考資料

- [Harness design for long-running apps — Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- [ハーネスエンジニアリング入門 — Qiita](https://qiita.com/nogataka/items/d1b3fcf355c630cd7fc8)
- [Claude Code ドキュメント](https://docs.anthropic.com/en/docs/claude-code)
