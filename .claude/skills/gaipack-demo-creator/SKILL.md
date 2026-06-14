---
name: gaipack-demo-creator
description: お客様向けデモアプリを Claude Code のマルチエージェント構成で自動生成するオーケストレーター。企業調査→仕様書→デザイン→実装→QA評価までを一気通貫で実行し、「生成」と「レビュー」を独立したサブエージェント（独立コンテキスト）に分離する。「デモアプリ作って」「デモ作成」「gaipack-demo-creator」「お客様向けデモ」「demo-creator」と言及された場合に使う。お客様名と求めるシステムが提示された場合もトリガーとなる。
---

# gaipack-demo-creator — オーケストレーター（Claude Edition）

お客様向けデモアプリを、Claude Code のサブエージェントを使い分けて自動生成する。
企業調査→仕様書→デザイン→実装→QA評価のパイプラインを、Claude Code 上のネイティブ skill として実行する。

## このskillの最重要原則: 生成とレビューの分離

各ステージは**独立した Agent ツール呼び出し（＝独立コンテキスト）**として起動する。
特にレビュー系（Spec Review / Design Review / Evaluator）は、生成したサブエージェントとは
**必ず別のサブエージェント**として起動すること。これにより:

- 生成時の思考過程を引き継がないため「自分の判断の正当化（motivated reasoning）」が起きない
- レビュアは成果物ファイルと仕様書という客観基準のみを見る

オーケストレーター（あなた）自身は各成果物の中身を精読しすぎず、**ファイルパスを受け渡す**ことで
コンテキストを軽く保つ。詳細な作業はサブエージェントに委譲する。

> このskillは設計上マルチエージェントである。各ステージで Agent ツールによるサブエージェント起動を
> 行うことが正規の動作であり、これは「ユーザーが明示的に依頼した spawn」に該当する。

## Step 0: 起動準備（パスの確定）

1. 入力（お客様名・求めるシステム）を確認する。不足していれば AskUserQuestion で「お客様名」「求めるシステム」を確認する。
2. Bash で以下を確定する（このskillはハーネスディレクトリ＝`.claude/skills/` を含むディレクトリで実行する想定）:
   ```bash
   # カレントがハーネスroot（01-researcher の skill がある場所）か確認
   test -f .claude/skills/01-researcher/SKILL.md || echo "NOT_HARNESS_ROOT"
   HARNESS_DIR="$(pwd)"
   PROJECT_ROOT="$(cd .. && pwd)"
   OUTPUT_DIR="$PROJECT_ROOT/demo"
   DOCS_DIR="$PROJECT_ROOT/docs"
   REFERENCES_DIR="$PROJECT_ROOT/references"
   echo "HARNESS_DIR=$HARNESS_DIR"; echo "OUTPUT_DIR=$OUTPUT_DIR"
   ```
   - `NOT_HARNESS_ROOT` が出たら、ユーザーに `gaipack-demo-creator/` ディレクトリで実行するよう促して停止する。
3. **上書き事故防止**: `OUTPUT_DIR`（`../demo`）が存在し中身が空でなければ停止し、`rm -rf ../demo` か
   `mv ../demo ../demo.$(date +%Y%m%d_%H%M%S)` をユーザーに促す。空 or 不在なら `mkdir -p ../demo/{spec,memory}` を作成。
4. `../docs/` と `../references/` の有無を確認し、後続ステージに渡すか判断する。

以降のサブエージェントには、上で確定した**絶対パス**を渡すこと。

## パイプライン

各ステージは下記の通りサブエージェントを起動する。Agent ツールの `subagent_type` は `general-purpose` を使う。
サブエージェントへのプロンプトは「指示書（ステージのSKILL.md）を読み、入力ファイルを読み、出力ファイルを書く」形にする。

### Agent 0: Document Reader（`../docs/` がある場合のみ）
- 条件: `$DOCS_DIR` が存在し、ファイルが1つ以上ある場合のみ。なければスキップ。
- サブエージェント起動（生成系）。プロンプト例:
  > `$HARNESS_DIR/.claude/skills/00-document-reader/SKILL.md` を読み、その指示に従ってください。
  > 読み込み対象: `$DOCS_DIR/` 配下の全ファイル。
  > 出力先: `$OUTPUT_DIR/memory/input_docs.md` に要約を書き出してください。
  > ユーザーの元の要件: {INPUT}

### Agent 1: Researcher（企業調査）
- サブエージェント起動（生成系）。WebSearch / WebFetch を使う。プロンプト例:
  > `$HARNESS_DIR/.claude/skills/01-researcher/SKILL.md` を読み、その指示に従ってお客様を調査してください。
  > `$OUTPUT_DIR/memory/input_docs.md` が存在すれば最初に読み、最優先の一次情報として扱ってください。
  > Web調査には WebSearch / WebFetch を使ってください。
  > 出力先: `$OUTPUT_DIR/memory/customer.md`
  > 調査対象: {INPUT}
- 完了後 `customer.md` が空でないことを確認。空なら停止。

### Agent 2: Planner（仕様書生成）
- サブエージェント起動（生成系）。プロンプト例:
  > `$HARNESS_DIR/.claude/skills/02-planner/SKILL.md` を読み、デモ仕様書を作成してください。
  > 入力: `$OUTPUT_DIR/memory/customer.md`、（あれば）`$OUTPUT_DIR/memory/input_docs.md`、
  > （`../references/` にMD/TXTがあれば）それらも gaipack 標準前提として読んでください。
  > 出力先: `$OUTPUT_DIR/spec/DEMO_SPEC.md`
  > ユーザーの元の要件: {INPUT}

### Agent 2.5: Spec Review（仕様書レビュー / 最大2ラウンド）
- **別のサブエージェント**を起動（レビュー系）。下記「レビュアペルソナ」を必ずプロンプト冒頭に含める。プロンプト例:
  > {レビュアペルソナ}
  > `$OUTPUT_DIR/spec/DEMO_SPEC.md` をレビューしてください。観点:
  > 1. 5セクションが全て埋まっているか 2. ペインと必須機能が論理的に対応 3. 機能が3〜5個に適切に絞られている
  > 4. デモシナリオが3分以内の自然なストーリー 5. 推察・仮説の根拠が具体的 6. モックデータ方針にリアリティ
  > 参考: `$OUTPUT_DIR/memory/customer.md`
  > 問題があれば `$OUTPUT_DIR/spec/SPEC_REVIEW.md` に各観点の判定（引用付き）と改善指示を、
  > 問題がなければ同ファイルに「PASS」とだけ書いてください。
- `SPEC_REVIEW.md` に「PASS」が含まれれば次へ。指摘ありなら **Planner を別サブエージェントで再起動**して修正させ、
  `SPEC_REVIEW.md` を削除してから再レビュー。最大2ラウンド。

### Agent 3: Designer（デザイン設計）
- サブエージェント起動（生成系）。プロンプト例:
  > `$HARNESS_DIR/.claude/skills/03-designer/SKILL.md` を読み、デザインドキュメントを作成してください。
  > 最初に必ず `/mnt/skills/public/frontend-design/SKILL.md` を読んでください。
  > 入力: `$OUTPUT_DIR/spec/DEMO_SPEC.md`、`$OUTPUT_DIR/memory/customer.md`
  > 出力先: `$OUTPUT_DIR/spec/DESIGN.md`（「frontend-design 準拠チェックリスト」セクションを必ず含める）

### Agent 3.5: Design Review（デザインレビュー / 最大2ラウンド）
- **別のサブエージェント**を起動（レビュー系）。プロンプト冒頭にレビュアペルソナを含め、
  frontend-design 6カテゴリ（Typography / Color / Motion / Spatial / Backgrounds / Anti-patterns）を
  1つずつ PASS/FAIL 判定させる。1つでもFAILなら全体FAIL。
  > 全6カテゴリPASS → `$OUTPUT_DIR/spec/DESIGN_REVIEW.md` に「PASS」、
  > 1つでもFAIL → 各カテゴリの判定（引用付き）と改善指示を同ファイルに書く。
- PASS で次へ。指摘ありなら **Designer を別サブエージェントで再起動**して修正→再レビュー。最大2ラウンド。

### Agent 4: Builder（実装+テスト）
- サブエージェント起動（生成系）。Bash / Edit / Write を使う。プロンプト例:
  > `$HARNESS_DIR/.claude/skills/04-builder/SKILL.md` を読み、デモアプリを実装してください。
  > 最初に必ず `/mnt/skills/public/frontend-design/SKILL.md` を読んでください。
  > 作業ディレクトリ: 最初に `cd $OUTPUT_DIR` を実行。`npm create vite@latest demo-app -- --template react-ts` で
  > `$OUTPUT_DIR/demo-app/` を生成。既存があれば中身を直接編集。
  > 入力: `$OUTPUT_DIR/spec/DEMO_SPEC.md`、`$OUTPUT_DIR/spec/DESIGN.md`、（あれば）`../references/`
  > 完了条件: `npx tsc --noEmit` と `npm run build` が通ること。
- 完了後 `$OUTPUT_DIR/demo-app/` が存在することを確認。

### Agent 5: Evaluator（QA評価 / 最大3ラウンド）
- まずオーケストレーター側で Bash によりビルド結果を取得:
  ```bash
  cd "$OUTPUT_DIR/demo-app" && (npx tsc --noEmit 2>&1 | tail -10; npm run build 2>&1 | tail -5)
  ```
- **別のサブエージェント**を起動（レビュー系）。プロンプト冒頭にレビュアペルソナを含める。プロンプト例:
  > {レビュアペルソナ}
  > `$HARNESS_DIR/.claude/skills/05-evaluator/SKILL.md` を読み、その評価基準で厳格に採点してください。
  > ビルド結果: {上のBash出力}
  > 入力: `$OUTPUT_DIR/spec/DEMO_SPEC.md`、`$OUTPUT_DIR/spec/DESIGN.md`、`$OUTPUT_DIR/demo-app/`（コードを読む）
  > 出力先: `$OUTPUT_DIR/spec/QA_REPORT.md`
- `QA_REPORT.md` に「PASS」が含まれ「FAIL」が含まれなければ合格→完了。
  不合格なら **Builder を別サブエージェントで再起動**して修正→`QA_REPORT.md`削除→再評価。最大3ラウンド。

## レビュアペルソナ（レビュー系サブエージェントに必ず含める）

```
あなたは独立した第三者のレビュー担当者です。この成果物を書いたのはあなた自身ではありません。
作成者の意図・事情・生成時の思考過程は一切共有されていません。
あなたの仕事は、与えられた成果物と仕様書という客観的な事実だけに基づき、欠陥を能動的に探し出すことです。

行動原則:
- 問題が「見つからないこと」より「見逃すこと」の方が重大な失敗である。粗探しの姿勢で臨むこと。
- 各観点を判定する際は、必ず成果物の該当箇所を引用し、その根拠を示してから PASS / FAIL を述べること。
- 根拠（引用）を示さない曖昧な合格（rubber-stamp）は禁止。引用できないものを PASS にしてはならない。
- 作成者を擁護したり、意図を好意的に推し量って甘く採点してはならない。判定基準は仕様書のみ。
- 「たぶん大丈夫」「おそらく問題ない」といった推測による合格判定をしてはならない。
```

## 完了報告

全ステージ完了後、生成物を一覧で報告する:
- `../demo/memory/input_docs.md`（顧客資料がある場合）
- `../demo/memory/customer.md`
- `../demo/spec/DEMO_SPEC.md` / `SPEC_REVIEW.md`
- `../demo/spec/DESIGN.md` / `DESIGN_REVIEW.md`
- `../demo/demo-app/`（起動: `cd ../demo/demo-app && npm install && npm run dev`）
- `../demo/spec/QA_REPORT.md`

レビューが最大ラウンドでも PASS しなかった場合は、残課題を率直に報告すること。
