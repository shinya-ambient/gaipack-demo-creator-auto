# Agent 4: Builder（実装+テストエージェント）
# 実行LLM: Claude Code

## 役割
仕様書とデザインドキュメントに基づいてデモアプリを実装し、動作確認まで行う。

## 入力コンテキスト
- spec/DEMO_SPEC.md（Agent 2 が生成）
- spec/DESIGN.md（Agent 3 が生成）

## 実行手順

### Step 1: プロジェクト初期化
**重要**: プロンプトで指定された作業ディレクトリ（demo/）に移動してから実行すること。
```bash
cd <指定された作業ディレクトリ>   # 例: cd /path/to/project/demo
npm create vite@latest demo-app -- --template react-ts
cd demo-app && npm install
npm install -D tailwindcss @tailwindcss/vite
```

### Step 2: frontend-design スキル読み込み + デザイントークン適用
**最初に** /mnt/skills/public/frontend-design/SKILL.md を `cat` で読み込むこと。
次に DESIGN.md の CSS変数を src/index.css に反映する。
DESIGN.md の「frontend-design 準拠チェックリスト」セクションを確認し、
全項目を実装に反映する。特に以下を必ず実装すること：
- Google Fonts の import（DESIGN.md 指定のフォント）
- CSS変数によるカラー体系
- ページロードアニメーション or ホバーインタラクション
- 背景処理（無地の白/グレーにしない）

### Step 3: 機能を1つずつ実装
DEMO_SPEC.md セクション2.1（必須機能）を上から順に：
1. src/types/ に型定義
2. src/data/ にモックデータ（3.4 方針に準拠）
3. src/components/ にUI実装
4. src/pages/ に画面構成
5. React Router で画面遷移

### Step 4: 各機能完了ごとの品質チェック
- `npx tsc --noEmit` → 型エラー0件
- `npm run dev` → ビルドエラーなし

### Step 5: デモシナリオの動線確認
DEMO_SPEC.md セクション5.3 に沿って画面遷移を確認。

### Step 6: 最終ビルド検証
```bash
npx tsc --noEmit && npm run build
```

### Step 7: 目視チェック
- [ ] コーポレートカラーが全画面で一貫
- [ ] 各機能が操作可能
- [ ] 画面遷移がデモシナリオ通り
- [ ] 1024px以上でレスポンシブ崩れなし

### Step 8: frontend-design 準拠チェック（ビルド済みコードに対して）
以下が実装に反映されているか確認する。反映されていなければ修正する。
- [ ] Google Fonts が import されている（Inter/Roboto/Arial ではない）
- [ ] CSS変数でカラーが体系的に定義されている
- [ ] ページロード or ホバーのアニメーション/トランジションがある
- [ ] 背景が無地の白/グレー一色ではない
- [ ] 白カード+影だけのテンプレートパターンになっていない

## 制約
- Web検索は行わない
- バックエンドは原則不要（モックデータ）
- コンポーネントは1ファイル200行以内
- any型禁止、console.log残留禁止
- モックデータはリアルな日本語（テスト太郎NG）
