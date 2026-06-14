#!/bin/bash
# =============================================================================
# gaipack-demo-creator Orchestrator — Claude Edition
#
# Claude Code のみでデモアプリを自動生成する。
#   - Claude Code : オーケストレーター、リサーチ、仕様/デザイン生成、実装、
#                   レビュー、QA評価（全工程）
#
# 各エージェントは独立した claude -p 呼び出し（＝独立コンテキスト）として実行し、
# エージェント間はファイルのみでコンテキストを受け渡す（context reset）。
# レビュー系エージェントは「生成」とは別セッションで実行することで、
# 同一モデルでも自己レビューバイアスを軽減する。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$SCRIPT_DIR"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/demo"
DOCS_DIR="$PROJECT_ROOT/docs"
REFERENCES_DIR="$PROJECT_ROOT/references"

# ── 色付き出力 ──
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ── レビューアペルソナ ──
# レビュー系エージェント（Agent 2.5 / 3.5 / 5）の system prompt に注入する。
# 生成エージェントと「別セッション（独立コンテキスト）」であることに加えて、
# 「自分は作成者ではない第三者」という人格を明示することで、自己レビューバイアスを軽減する。
# 同一モデルのため、せめて『正当化の遮断』と『エビデンス必須化』で分離を最大化する。
REVIEWER_PERSONA='あなたは独立した第三者のレビュー担当者です。この成果物を書いたのはあなた自身ではありません。
作成者の意図・事情・生成時の思考過程は一切共有されていません。
あなたの仕事は、与えられた成果物と仕様書という客観的な事実だけに基づき、欠陥を能動的に探し出すことです。

行動原則:
- 問題が「見つからないこと」より「見逃すこと」の方が重大な失敗である。粗探しの姿勢で臨むこと。
- 各観点を判定する際は、必ず成果物の該当箇所を引用し、その根拠を示してから PASS / FAIL を述べること。
- 根拠（引用）を示さない曖昧な合格（rubber-stamp）は禁止。引用できないものを PASS にしてはならない。
- 作成者を擁護したり、意図を好意的に推し量って甘く採点してはならない。判定基準は仕様書のみ。
- 「たぶん大丈夫」「おそらく問題ない」といった推測による合格判定をしてはならない。'

log_agent() {
  local color="$1" llm="$2" name="$3"
  echo -e "\n${color}━━━ [$llm] $name ━━━${NC}\n"
}
log_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
log_fail() { echo -e "${RED}❌ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# ── 前提チェック ──
check_cli() {
  if ! command -v "$1" &> /dev/null; then
    echo -e "${RED}Error: $1 が見つかりません。インストールしてください。${NC}"
    echo "$2"
    exit 1
  fi
}

check_cli "claude" "https://docs.anthropic.com/en/docs/claude-code"

# ── 引数チェック ──
if [ $# -lt 1 ]; then
  cat << 'USAGE'
Usage: ./run.sh <入力ファイル or 入力テキスト>

例:
  ./run.sh input.md
  ./run.sh 'お客様名: トヨタ自動車  求めているシステム: 部品在庫管理ダッシュボード'

前提条件:
  - claude (Claude Code)  がインストール済み
USAGE
  exit 1
fi

INPUT="$1"
if [ -f "$INPUT" ]; then
  INPUT_TEXT=$(cat "$INPUT")
else
  INPUT_TEXT="$INPUT"
fi

echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   gaipack-demo-creator — Claude Edition          ║${NC}"
echo -e "${CYAN}║   Powered by Claude Code                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "プロジェクトルート: ${PROJECT_ROOT}"
echo -e "出力先:             ${OUTPUT_DIR}"
echo -e "顧客受領資料:       ${DOCS_DIR}$([ -d "$DOCS_DIR" ] && echo '' || echo ' (なし)')"
echo -e "gaipack標準参照:    ${REFERENCES_DIR}$([ -d "$REFERENCES_DIR" ] && echo '' || echo ' (なし)')"
echo -e "入力: ${INPUT_TEXT:0:80}..."
echo ""

# ── ディレクトリ準備 ──
# 既存の demo/ があり中身が空でない場合は、上書き事故を防ぐためにエラー停止する。
# ユーザーが意図的に流用したい場合は、リネーム or 削除してから再実行する想定。
if [ -d "$OUTPUT_DIR" ] && [ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
  log_fail "既存の demo/ ディレクトリが見つかりました: $OUTPUT_DIR"
  echo ""
  echo -e "${YELLOW}上書き事故を防ぐため、ハーネスは既存の demo/ には書き込みません。${NC}"
  echo "以下のいずれかの対応をしてから再実行してください:"
  echo ""
  echo -e "  ${CYAN}# 既存を破棄して新規作成する場合:${NC}"
  echo "  rm -rf \"$OUTPUT_DIR\""
  echo ""
  echo -e "  ${CYAN}# 既存をバックアップとして残す場合:${NC}"
  echo "  mv \"$OUTPUT_DIR\" \"${OUTPUT_DIR}.\$(date +%Y%m%d_%H%M%S)\""
  echo ""
  exit 1
fi

mkdir -p "$OUTPUT_DIR"/{spec,memory}
log_ok "demo/ ディレクトリを新規作成しました: $OUTPUT_DIR"

# ======================================================================
# Agent 0: Document Reader (Claude Code) — Pre-step
# プロジェクトルートの docs/ 配下に顧客受領ドキュメントがある場合のみ実行
# PDF / DOCX / XLSX / PPTX / MD / TXT / PNG / JPG を読み込み demo/memory/input_docs.md に要約
# ======================================================================
INPUT_DOCS_BLOCK=""
if [ -d "$DOCS_DIR" ] && [ -n "$(ls -A "$DOCS_DIR" 2>/dev/null)" ]; then
  log_agent "$BLUE" "Claude Code" "Agent 0: Document Reader（顧客ドキュメント読み込み）"

  echo -e "docs/ を検出しました。読み込み対象:"
  ls -1 "$DOCS_DIR" | sed 's/^/  - /'
  echo ""

  DOC_READER_PROMPT=$(cat << EOF
以下のスキル定義に従って、$DOCS_DIR 配下の顧客受領ドキュメントを読み込み、
$OUTPUT_DIR/memory/input_docs.md に要約してください。

## スキル定義:
$(cat "$HARNESS_DIR/.claude/skills/00-document-reader/SKILL.md")

## ユーザーの元の要件:
$INPUT_TEXT

## 読み込み対象ディレクトリ: $DOCS_DIR/
## 出力先ファイル: $OUTPUT_DIR/memory/input_docs.md
EOF
)

  claude -p "$DOC_READER_PROMPT" --allowedTools "Edit,Write,Read,Bash" 2>/tmp/agent0_err.log || {
    log_warn "Claude Code (Document Reader) でエラー発生。ログ: /tmp/agent0_err.log"
  }

  if [ -f "$OUTPUT_DIR/memory/input_docs.md" ]; then
    log_ok "input_docs.md 生成完了（Claude Code）"
    INPUT_DOCS_BLOCK=$(cat << EOF

## 顧客受領ドキュメント要約 (input_docs.md):
$(cat "$OUTPUT_DIR/memory/input_docs.md")
EOF
)
  else
    log_warn "input_docs.md が生成されませんでした。顧客ドキュメントなしとして続行します。"
  fi
else
  echo -e "${YELLOW}ℹ️  $DOCS_DIR が存在しない or 空のため、顧客ドキュメント読み込みをスキップします${NC}"
fi

# ======================================================================
# references/ 読み込み (gaipack 標準アーキ・技術スタック)
# プロジェクトルートの references/ 配下にファイルがある場合のみ読み込み、
# Agent 2 (Planner) と Agent 4 (Builder) のプロンプトに含める
# 対応形式: MD / TXT のみ（軽量に保つ。バイナリは無視）
# ======================================================================
REFERENCES_BLOCK=""
if [ -d "$REFERENCES_DIR" ] && [ -n "$(find "$REFERENCES_DIR" -type f \( -name "*.md" -o -name "*.txt" \) 2>/dev/null)" ]; then
  echo -e "${CYAN}ℹ️  references/ を検出しました。gaipack 標準ドキュメントを読み込みます${NC}"
  REF_CONTENT=""
  while IFS= read -r ref_file; do
    rel_path="${ref_file#$REFERENCES_DIR/}"
    REF_CONTENT+=$'\n### references/'"${rel_path}"$'\n'"$(cat "$ref_file")"$'\n'
    echo "  - $rel_path"
  done < <(find "$REFERENCES_DIR" -type f \( -name "*.md" -o -name "*.txt" \) | sort)

  REFERENCES_BLOCK=$(cat << EOF

## gaipack 標準参照資料 (references/):
以下は gaipack の標準アーキテクチャ・技術スタック・ガイドラインです。
仕様書および実装はこれらを前提として作成してください。
$REF_CONTENT
EOF
)
else
  echo -e "${YELLOW}ℹ️  $REFERENCES_DIR が存在しない or MD/TXT がないため、references 読み込みをスキップします${NC}"
fi

# ======================================================================
# Agent 1: Researcher (Claude Code)
# WebSearch / WebFetch で企業情報を調査
# ======================================================================
log_agent "$BLUE" "Claude Code" "Agent 1: Researcher（企業調査）"

RESEARCHER_PROMPT=$(cat << EOF
以下のスキル定義に従ってお客様を調査し、結果を $OUTPUT_DIR/memory/customer.md に書き出してください。
Web調査には WebSearch / WebFetch ツールを使用してください。

## スキル定義:
$(cat "$HARNESS_DIR/.claude/skills/01-researcher/SKILL.md")

---
以下のお客様について調査してください：

$INPUT_TEXT
$INPUT_DOCS_BLOCK

## 出力先ファイル: $OUTPUT_DIR/memory/customer.md
EOF
)

claude -p "$RESEARCHER_PROMPT" --allowedTools "WebSearch,WebFetch,Write,Read" 2>/tmp/agent1_err.log || {
  log_warn "Claude Code (Researcher) でエラーが発生しました"
}

if [ -s "$OUTPUT_DIR/memory/customer.md" ]; then
  log_ok "customer.md 生成完了（Claude Code）"
else
  log_fail "customer.md が空です"
  cat /tmp/agent1_err.log
  exit 1
fi

# ======================================================================
# Agent 2: Planner (Claude Code)
# 仕様書を生成
# ======================================================================
log_agent "$BLUE" "Claude Code" "Agent 2: Planner（仕様書生成）"

PLANNER_PROMPT=$(cat << EOF
以下のスキル定義に従って、デモ仕様書を $OUTPUT_DIR/spec/DEMO_SPEC.md に作成してください。

## スキル定義:
$(cat "$HARNESS_DIR/.claude/skills/02-planner/SKILL.md")

## ユーザーの元の要件:
$INPUT_TEXT

## 調査結果 (customer.md):
$(cat "$OUTPUT_DIR/memory/customer.md")
$INPUT_DOCS_BLOCK
$REFERENCES_BLOCK

## 出力先ファイル: $OUTPUT_DIR/spec/DEMO_SPEC.md
EOF
)

claude -p "$PLANNER_PROMPT" --allowedTools "Edit,Write,Read" 2>/tmp/agent2_err.log || {
  log_warn "Claude Code (Planner) でエラー発生。ログを確認してください。"
}

if [ -f "$OUTPUT_DIR/spec/DEMO_SPEC.md" ]; then
  log_ok "DEMO_SPEC.md 生成完了（Claude Code）"
else
  log_fail "DEMO_SPEC.md が見つかりません"
  exit 1
fi

# ======================================================================
# Agent 2.5: Spec Review (Claude Code)
# 仕様書をレビュー（Planner とは別セッションで独立レビュー）
# 修正後は再レビューし、PASSするまで最大2ラウンド回す
# ======================================================================
SPEC_REVIEW_MAX=2
for spec_round in $(seq 1 $SPEC_REVIEW_MAX); do
  log_agent "$GREEN" "Claude Code" "Agent 2.5: Spec Review（仕様書レビュー ラウンド ${spec_round}/${SPEC_REVIEW_MAX}）"

  SPEC_REVIEW_PROMPT=$(cat << EOF
以下のデモ仕様書をレビューしてください。

レビュー観点:
1. 5セクション（業務コンテキスト/スコープ/データ入出力/非機能要件/判断基準）が全て埋まっているか
2. ペインポイントと必須機能が論理的に対応しているか
3. デモで見せる機能が3〜5個に適切に絞られているか
4. デモシナリオが3分以内の自然なストーリーか
5. 推察・仮説の根拠が具体的か
6. モックデータ方針がリアリティのあるものか

問題があれば $OUTPUT_DIR/spec/SPEC_REVIEW.md に改善指示を書いてください。
問題がなければ $OUTPUT_DIR/spec/SPEC_REVIEW.md に「PASS」とだけ書いてください。

仕様書:
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")

お客様情報:
$(cat "$OUTPUT_DIR/memory/customer.md")
EOF
  )

  claude -p "$SPEC_REVIEW_PROMPT" --append-system-prompt "$REVIEWER_PERSONA" --allowedTools "Write,Read" 2>/tmp/agent2_5_round${spec_round}.log || {
    log_warn "Claude Code (Spec Review) でエラー発生"
  }

  if [ -f "$OUTPUT_DIR/spec/SPEC_REVIEW.md" ] && grep -q "PASS" "$OUTPUT_DIR/spec/SPEC_REVIEW.md"; then
    log_ok "仕様書レビュー PASS（ラウンド $spec_round, Claude Code）"
    break
  elif [ ! -f "$OUTPUT_DIR/spec/SPEC_REVIEW.md" ]; then
    log_warn "SPEC_REVIEW.md が生成されませんでした（ラウンド ${spec_round}）。レビューをスキップして次へ進みます。"
    break
  else
    log_warn "仕様書にレビュー指摘あり（ラウンド ${spec_round}）"
    if [ "$spec_round" -lt "$SPEC_REVIEW_MAX" ]; then
      log_agent "$BLUE" "Claude Code" "Agent 2: Planner（仕様書修正 ラウンド ${spec_round}）"

      SPEC_FIX_PROMPT=$(cat << EOF
以下のレビュー指摘に基づいて spec/DEMO_SPEC.md を修正してください。

## レビュー指摘:
$(cat "$OUTPUT_DIR/spec/SPEC_REVIEW.md")

## 現在の仕様書:
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")
EOF
      )

      claude -p "$SPEC_FIX_PROMPT" --allowedTools "Edit,Write,Read" 2>/dev/null || true
      log_ok "仕様書を修正しました。Claude で再レビューします。"
      rm -f "$OUTPUT_DIR/spec/SPEC_REVIEW.md"
    else
      log_warn "仕様書レビュー最大ラウンド到達。指摘を残したまま次へ進みます。"
    fi
  fi
done

# ======================================================================
# Agent 3: Designer (Claude Code)
# デザインドキュメントを生成
# ======================================================================
log_agent "$BLUE" "Claude Code" "Agent 3: Designer（デザイン設計）"

DESIGNER_PROMPT=$(cat << EOF
以下のスキル定義に従って、デザインドキュメントを spec/DESIGN.md に作成してください。
/mnt/skills/public/frontend-design/SKILL.md も必ず参照してください。

## スキル定義:
$(cat "$HARNESS_DIR/.claude/skills/03-designer/SKILL.md")

## 仕様書 (DEMO_SPEC.md):
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")

## お客様情報 (customer.md):
$(cat "$OUTPUT_DIR/memory/customer.md")
EOF
)

claude -p "$DESIGNER_PROMPT" --allowedTools "Edit,Write,Read" 2>/tmp/agent3_err.log || {
  log_warn "Claude Code (Designer) でエラー発生"
}

if [ -f "$OUTPUT_DIR/spec/DESIGN.md" ]; then
  log_ok "DESIGN.md 生成完了（Claude Code）"
else
  log_fail "DESIGN.md が見つかりません"
  exit 1
fi

# ======================================================================
# Agent 3.5: Design Review (Claude Code)
# デザインドキュメントをレビュー（Designer とは別セッションで独立レビュー）
# 修正後は再レビューし、PASSするまで最大2ラウンド回す
# ======================================================================
DESIGN_REVIEW_MAX=2
for design_round in $(seq 1 $DESIGN_REVIEW_MAX); do
  log_agent "$GREEN" "Claude Code" "Agent 3.5: Design Review（デザインレビュー ラウンド ${design_round}/${DESIGN_REVIEW_MAX}）"

  DESIGN_REVIEW_PROMPT=$(cat << EOF
以下のデザインドキュメントをレビューしてください。

## 最重要: frontend-design 準拠チェック（1つでもFAILなら全体FAIL）

出力先ファイル: $OUTPUT_DIR/spec/DESIGN_REVIEW.md

DESIGN.md 内に「frontend-design 準拠チェックリスト」セクションが存在するか確認し、
以下の6カテゴリを1つずつ判定してください。

### 1. Typography
- 見出し・本文フォントが Inter / Roboto / Arial / system fonts / Space Grotesk ではないこと
- 見出しと本文で異なるフォントがペアリングされていること
- → PASS / FAIL（理由）

### 2. Color
- 紫グラデーション + 白背景のクリシェになっていないこと
- CSS変数で体系的に定義されていること
- コーポレートカラーが支配的に使われていること
- → PASS / FAIL（理由）

### 3. Motion
- ページロードアニメーションが定義されていること
- ホバー/フォーカスのインタラクションが定義されていること
- → PASS / FAIL（理由）

### 4. Spatial（空間構成）
- 予測可能なグリッド一辺倒ではない空間的な仕掛けがあること
- 具体的な手法（asymmetry / overlap / diagonal flow 等）が明記されていること
- → PASS / FAIL（理由）

### 5. Backgrounds（背景）
- 無地の白 or グレー一色ではない背景処理があること
- 具体的な手法が明記されていること
- → PASS / FAIL（理由）

### 6. Anti-patterns
- 「frontend-design 準拠チェックリスト」セクション自体が DESIGN.md 内に存在すること
  - 存在しない場合 → このカテゴリは自動的にFAIL
- 全体が「AIが作った感」のないデザインになっていること
- → PASS / FAIL（理由）

## 追加レビュー観点
- 仕様書の画面構成に対応するコンポーネントが全て列挙されているか
- お客様ブランドとの整合性

## 判定ルール
- 6カテゴリ全てPASS → $OUTPUT_DIR/spec/DESIGN_REVIEW.md に「PASS」とだけ書く
- 1つでもFAIL → $OUTPUT_DIR/spec/DESIGN_REVIEW.md に各カテゴリの判定結果と改善指示を書く

デザインドキュメント:
$(cat "$OUTPUT_DIR/spec/DESIGN.md")

仕様書:
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")
EOF
  )

  claude -p "$DESIGN_REVIEW_PROMPT" --append-system-prompt "$REVIEWER_PERSONA" --allowedTools "Write,Read" 2>/tmp/agent3_5_round${design_round}.log || {
    log_warn "Claude Code (Design Review) でエラー発生"
  }

  if [ -f "$OUTPUT_DIR/spec/DESIGN_REVIEW.md" ] && grep -q "PASS" "$OUTPUT_DIR/spec/DESIGN_REVIEW.md"; then
    log_ok "デザインレビュー PASS（ラウンド $design_round, Claude Code）"
    break
  elif [ ! -f "$OUTPUT_DIR/spec/DESIGN_REVIEW.md" ]; then
    log_warn "DESIGN_REVIEW.md が生成されませんでした（ラウンド ${design_round}）。レビューをスキップして次へ進みます。"
    break
  else
    log_warn "デザインにレビュー指摘あり（ラウンド ${design_round}）"
    if [ "$design_round" -lt "$DESIGN_REVIEW_MAX" ]; then
      log_agent "$BLUE" "Claude Code" "Agent 3: Designer（デザイン修正 ラウンド ${design_round}）"

      claude -p "以下のレビュー指摘に基づいて spec/DESIGN.md を修正してください。

## レビュー指摘:
$(cat "$OUTPUT_DIR/spec/DESIGN_REVIEW.md")

## 現在のデザインドキュメント:
$(cat "$OUTPUT_DIR/spec/DESIGN.md")" --allowedTools "Edit,Write,Read" 2>/dev/null || true
      log_ok "デザインドキュメントを修正しました。Claude で再レビューします。"
      rm -f "$OUTPUT_DIR/spec/DESIGN_REVIEW.md"
    else
      log_warn "デザインレビュー最大ラウンド到達。指摘を残したまま次へ進みます。"
    fi
  fi
done

# ======================================================================
# Agent 4: Builder (Claude Code)
# デモアプリを実装
# ======================================================================
log_agent "$BLUE" "Claude Code" "Agent 4: Builder（実装+テスト）"

BUILDER_PROMPT=$(cat << EOF
以下のスキル定義に従ってデモアプリを実装してください。

## 重要: 作業ディレクトリ
すべての実装は $OUTPUT_DIR/ 配下に行ってください。
- プロジェクト初期化時は最初に \`cd $OUTPUT_DIR\` を実行する
- \`npm create vite@latest demo-app\` で \`$OUTPUT_DIR/demo-app/\` が生成される想定
- 既に $OUTPUT_DIR/demo-app/ が存在する場合は、その中身を直接編集する

## スキル定義:
$(cat "$HARNESS_DIR/.claude/skills/04-builder/SKILL.md")

## 仕様書 (DEMO_SPEC.md):
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")

## デザインドキュメント (DESIGN.md):
$(cat "$OUTPUT_DIR/spec/DESIGN.md")
$REFERENCES_BLOCK
EOF
)

claude -p "$BUILDER_PROMPT" --allowedTools "Edit,Write,Read,Bash" 2>/tmp/agent4_err.log || {
  log_warn "Claude Code (Builder) でエラー発生"
}

if [ -d "$OUTPUT_DIR/demo-app" ]; then
  log_ok "demo-app/ 生成完了（Claude Code）"
else
  log_fail "demo-app/ が見つかりません ($OUTPUT_DIR/demo-app/)"
  exit 1
fi

# ======================================================================
# Agent 5: Evaluator (Claude Code) — 最大3ラウンド
# Builder とは別セッションで、実装したコードを独立レビュー
# ======================================================================
MAX_ROUNDS=3
for round in $(seq 1 $MAX_ROUNDS); do
  log_agent "$GREEN" "Claude Code" "Agent 5: Evaluator（QA評価 ラウンド ${round}/${MAX_ROUNDS}）"

  # ビルドチェックを事前に実行
  BUILD_RESULT=""
  if [ -d "$OUTPUT_DIR/demo-app" ]; then
    BUILD_RESULT=$(cd "$OUTPUT_DIR/demo-app" && npx tsc --noEmit 2>&1 | tail -10; npm run build 2>&1 | tail -5) || true
  fi

  EVALUATOR_PROMPT=$(cat << EOF
$(cat "$HARNESS_DIR/.claude/skills/05-evaluator/SKILL.md")

---
評価ラウンド: $round / $MAX_ROUNDS

## ビルド結果:
$BUILD_RESULT

## 仕様書 (DEMO_SPEC.md):
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")

## デザインドキュメント (DESIGN.md):
$(cat "$OUTPUT_DIR/spec/DESIGN.md")

$OUTPUT_DIR/demo-app/ ディレクトリのコードを読み、上記仕様書と照合して
$OUTPUT_DIR/spec/QA_REPORT.md を作成してください。
EOF
  )

  claude -p "$EVALUATOR_PROMPT" --append-system-prompt "$REVIEWER_PERSONA" --allowedTools "Read,Bash,Write" 2>/tmp/agent5_round${round}.log || {
    log_warn "Claude Code (Evaluator) でエラー発生"
  }

  # QA結果を確認
  if [ -f "$OUTPUT_DIR/spec/QA_REPORT.md" ]; then
    if grep -q "PASS" "$OUTPUT_DIR/spec/QA_REPORT.md" && ! grep -q "FAIL" "$OUTPUT_DIR/spec/QA_REPORT.md"; then
      log_ok "QA合格！（ラウンド $round, Claude Code）"
      break
    else
      log_warn "QA不合格（ラウンド ${round}）"
      if [ "$round" -lt "$MAX_ROUNDS" ]; then
        log_agent "$BLUE" "Claude Code" "Agent 4: Builder（修正 ラウンド $((round + 1))）"

        claude -p "以下のQA評価レポートの改善指示に従って demo-app/ を修正してください。

## QA評価レポート:
$(cat "$OUTPUT_DIR/spec/QA_REPORT.md")

## 仕様書:
$(cat "$OUTPUT_DIR/spec/DEMO_SPEC.md")

## デザイン:
$(cat "$OUTPUT_DIR/spec/DESIGN.md")" --allowedTools "Edit,Write,Read,Bash" 2>/dev/null || true

        rm -f "$OUTPUT_DIR/spec/QA_REPORT.md"
      else
        log_fail "最大ラウンド($MAX_ROUNDS)到達。QA_REPORT.md の残課題を確認してください。"
      fi
    fi
  else
    log_warn "QA_REPORT.md が生成されませんでした（ラウンド ${round}）。QA評価をスキップします。"
    break
  fi
done

# ── 完了 ──
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              デモ作成完了！                       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "📊 エージェント実行サマリー:"
echo -e "  ${BLUE}[Claude Code]${NC} Agent 0: Document Reader → demo/memory/input_docs.md（../docs/ がある場合のみ）"
echo -e "  ${BLUE}[Claude Code]${NC} Agent 1: Researcher    → demo/memory/customer.md"
echo -e "  ${BLUE}[Claude Code]${NC} Agent 2: Planner      → demo/spec/DEMO_SPEC.md"
echo -e "  ${GREEN}[Claude Code]${NC} Agent 2.5: Spec Review → demo/spec/SPEC_REVIEW.md"
echo -e "  ${BLUE}[Claude Code]${NC} Agent 3: Designer     → demo/spec/DESIGN.md"
echo -e "  ${GREEN}[Claude Code]${NC} Agent 3.5: Design Review → demo/spec/DESIGN_REVIEW.md"
echo -e "  ${BLUE}[Claude Code]${NC} Agent 4: Builder      → demo/demo-app/"
echo -e "  ${GREEN}[Claude Code]${NC} Agent 5: Evaluator    → demo/spec/QA_REPORT.md"
echo ""
echo "出力ディレクトリ: $OUTPUT_DIR"
echo ""
echo "生成されたファイル:"
echo "  📥 demo/memory/input_docs.md — 顧客受領ドキュメント要約（Claude、../docs/ がある場合のみ）"
echo "  📋 demo/memory/customer.md   — お客様情報（Claude 調査）"
echo "  📝 demo/spec/DEMO_SPEC.md    — デモ仕様書（Claude 生成 → Claude レビュー済）"
echo "  🎨 demo/spec/DESIGN.md       — デザイン（Claude 生成 → Claude レビュー済）"
echo "  💻 demo/demo-app/            — デモアプリ（Claude 実装）"
echo "  ✅ demo/spec/QA_REPORT.md    — QA評価（Claude 評価）"
