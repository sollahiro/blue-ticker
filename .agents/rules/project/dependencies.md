# 依存関係の管理方針

レイヤー間の依存ルールは `AGENTS.md` を参照。

## 外部パッケージ依存

外部パッケージの追加は最小限に抑える。

- **セキュリティ**: 依存パッケージはサプライチェーン攻撃の攻撃面になる。
- **容量**: ビルド時間・`Package.resolved` の肥大化を防ぐ。

Foundation / 標準ライブラリで賄えるものは外部パッケージを追加しない。

現在の依存パッケージと採用理由は `Package.swift` の各 `.package(...)` 宣言に付随するコメントを正本とする（ここに二重管理の一覧は置かない。過去に表だけ更新されず実態とズレた実績があるため）。

## 新規パッケージ追加の判断基準

以下をすべて満たす場合のみ追加を検討する。

1. Foundation・標準ライブラリで実現不可能
2. 既存の依存パッケージでも実現不可能
3. メンテナンスが継続されている実績あるパッケージ

基準を満たすと判断した場合でも、`Package.swift` を変更する前にユーザーへ確認を取ること。確認時は追加パッケージ名・代替不可の理由・使用箇所を伝える。

## Linux 互換

`URLSession` は `FoundationNetworking`、`XMLParser` は `FoundationXML` の条件付き import が必要。macOS 専用 API（`Security.framework` 等）は `#if canImport(...)` でガードする。

**swift-nio / MemberImportVisibility（一時措置）**: Vapor 経由の swift-nio が Linux で `MemberImportVisibility`（Swift 6.1+）下でエラー化するため、Linux の `swift build` / `swift test` / Docker には `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` を付ける（`AGENTS.md`「Cursor Cloud」、`.github/workflows/ci.yml`、`Dockerfile`）。swift-nio 修正後に除去する（`docs/operations.md` にも同じ注意あり）。
