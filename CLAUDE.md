# gaipack-demo-creator — Claude Edition

## 概要
お客様向けデモアプリを、Claude Code のみのマルチエージェント構成で作成するハーネスです。
全工程（リサーチ／仕様・デザイン生成／実装／レビュー／QA評価）を Claude Code の skill として実行します。
各ステージは独立したサブエージェント（Agent ツール＝独立コンテキスト）として動作し、
役割ごとに分離してファイルでコンテキストを受け渡します。
レビュー系エージェント（2.5 / 3.5 / 5）は「生成」とは別サブエージェントで実行することで、
同一モデルでも自己レビューバイアスを軽減します。

## アーキテクチャ

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Claude Code (Orchestrator)                        │
│              /gaipack-demo-creator skill を実行                       │
├──────────┬──────────┬──────────┬──────────┬──────────┬────────────────┤
│ Agent 0  │ Agent 1  │ Agent 2  │ Agent 3  │ Agent 4  │ Agent 5        │
│ DocReader│Researcher│ Planner  │ Designer │ Builder  │ Evaluator      │
│(optional)│          │          │          │          │                │
│          │          │          │          │          │                │
│ Claude   │ Claude   │ Claude   │ Claude   │ Claude   │ Claude         │
│ Code     │ Code     │ Code     │ Code     │ Code     │ Code           │
├──────────┼──────────┼──────────┼──────────┼──────────┼────────────────┤
│顧客資料  │ Web検索  │ 仕様書   │ デザイン │ 実装     │ レビュー       │
│読み込み  │ 企業調査 │ 生成     │ 設計     │ テスト   │ QA評価         │
└────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬───────────┘
     ↓          ↓          ↓          ↓          ↓          ↓
 input_docs.md customer.md DEMO_SPEC.md DESIGN.md demo-app/ QA_REPORT.md
```

## 各エージェントの役割

すべて Claude Code で実行する。レビュー系（2.5 / 3.5 / 5）は生成エージェントとは
別セッション（独立コンテキスト）で起動し、第三者視点でのレビューを担保する。

| Agent | 実行LLM | 役割 | 主な使用ツール |
|-------|---------|------|----------------|
| 0. Document Reader | **Claude Code** | 顧客受領資料の読み込み（optional） | Read / Bash（PDF/Docx/Xlsx等の多形式対応） |
| 1. Researcher | **Claude Code** | Web調査・企業情報収集 | WebSearch / WebFetch |
| 2. Planner | **Claude Code** | 仕様書生成 | Write / Read |
| 2.5 Spec Review | **Claude Code** | 仕様書レビュー（別セッション） | Write / Read |
| 3. Designer | **Claude Code** | デザイン設計 | frontend-design スキル連携 |
| 3.5 Design Review | **Claude Code** | デザインレビュー（別セッション） | Write / Read |
| 4. Builder | **Claude Code** | 実装+テスト | Edit / Write / Read / Bash |
| 5. Evaluator | **Claude Code** | QA評価・レビュー（別セッション） | Read / Bash / Write |

## レビューの独立性（分離設計）

同一モデル（Claude）でも「生成」と「レビュー」を構造的に分離するため、以下を**設計上の必須ルール**とする。
レビュー系エージェント（2.5 / 3.5 / 5）を改修する際もこの分離を崩さないこと。

1. **別のサブエージェント（独立コンテキスト）で起動**
   レビューは生成とは別のサブエージェント（Agent ツール）として起動する。会話履歴・生成時の思考過程は引き継がない。
   → 生成理由を覚えていないため「自分の判断の正当化（motivated reasoning）」が起きない。

2. **生成時の文脈を渡さない**
   レビュープロンプトには「成果物そのもの＋仕様書（客観基準）」のみを渡す。
   生成エージェントのメモ・判断理由・思考ログは構造的に渡さない。

3. **第三者ペルソナを注入**
   レビュアペルソナ（「自分は作成者ではない第三者」「欠陥を能動的に探す」「根拠（引用）なしの PASS 禁止」）を
   全レビュー起動に付与する。オーケストレーター skill（SKILL.md）のレビュアペルソナを、
   レビューサブエージェントのプロンプト冒頭に必ず含める。

4. **エビデンス必須化（rubber-stamp 禁止）**
   各観点の判定は該当箇所の引用を伴うこと。推測による合格判定を禁止する。

**限界の明示**: 同一モデルのため「学習由来の盲点」は生成・レビューで共通し得る（別モデルなら補完できた部分）。
上記 1〜4 は「正当化の遮断」には有効だが、「モデル固有の盲点の補完」には限界がある点を理解した上で運用する。
将来モデル多様性を回復したい場合は、レビューのみ別 Claude モデルを `--model` で指定する拡張余地を残している。

## 前提条件
以下のCLIがインストール済みであること：
```bash
# Claude Code
# https://docs.anthropic.com/en/docs/claude-code
```

## ディレクトリ構成（前提）

gaipack-demo-creator は以下のプロジェクト構成で動作する前提：

```
{プロジェクト}/                ← 例: 202605-toyota-system/
├── docs/                     ← 顧客受領資料（optional）
├── references/               ← gaipack 標準アーキ・技術スタック（optional, MD/TXT）
├── proposal/                 ← 提案書（ハーネス対象外）
├── demo/                     ← ハーネス出力先
│   ├── memory/{input_docs.md, customer.md}
│   ├── spec/{DEMO_SPEC.md, DESIGN.md, QA_REPORT.md, *_REVIEW.md}
│   └── demo-app/
└── gaipack-demo-creator/     ← ハーネス本体
    └── .claude/skills/
        ├── gaipack-demo-creator/SKILL.md  ← オーケストレーター skill
        └── 00〜05/SKILL.md                 ← 各ステージの指示書
```

## 使い方

Claude Code の skill として実行する。出力先は `../demo/`。

`gaipack-demo-creator/` ディレクトリで Claude Code を開き、skill を呼び出す:
```
/gaipack-demo-creator お客様名: ○○株式会社  求めているシステム: 在庫管理ダッシュボード
```
オーケストレーター skill（`.claude/skills/gaipack-demo-creator/SKILL.md`）が各ステージを
**サブエージェント（Agent ツール＝独立コンテキスト）**として起動する。生成とレビューが
別サブエージェントに分離されるため、分離設計がネイティブに担保される。

## 情報補完の原則
インプットで埋まっている項目はそのまま採用し、足りない項目は以下の順で補完：
1. **顧客受領資料（../docs/）記載** → そのまま採用 `（出典: 顧客受領資料 {ファイル名}）`（最優先の一次情報）
2. **gaipack 標準参照（../references/）記載** → 標準アーキ・技術スタックの前提として採用
3. インプットの文脈から推察 → `（推察: {根拠}）`
4. 公開情報から調査 → `（出典: {URL}）`
5. 業界傾向から仮説 → `⚠️ 仮説:` （商談で要確認）
6. 推察不可 → `[要ヒアリング]`

## 顧客受領ドキュメントの扱い
プロジェクトルートの `docs/` ディレクトリ（`gaipack-demo-creator/` から見ると `../docs/`）にファイルを配置すると、Agent 0（Document Reader）が自動で読み込み、`../demo/memory/input_docs.md` に要約する。これは最優先の一次情報として Agent 1/2 に引き継がれる。
顧客資料の記載と Web 調査結果が矛盾した場合は、顧客資料を採用する。

## gaipack 標準参照の扱い
プロジェクトルートの `references/` ディレクトリ（`../references/`）に MD/TXT を配置すると、Agent 2（Planner）と Agent 4（Builder）のプロンプトに自動で含まれる。仕様書も実装も gaipack の標準前提に沿って生成される。
