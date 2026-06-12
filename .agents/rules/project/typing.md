# 型・並行性の規約

Swift 6 言語モードへの移行を見据え、`StrictConcurrency` を有効にしている。コンパイラ警告を増やさないこと。

## 設計ガイダンス

### struct / Codable と辞書の使い分け

| ケース | 使うもの |
|---|---|
| JSON / キャッシュ / レイヤー間のデータ | `Codable` struct（または `toDictionary()` で `[String: Any]` へ変換） |
| ロジックを持つオブジェクト | `struct` + メソッド、共有可変状態は `actor` |
| 一時的な戻り値（2〜3フィールド） | ラベル付きタプル `(current: Double?, prior: Double?)` |
| EDINET API レスポンス等の動的 JSON | `[String: Any]`（外部境界に限定） |

複数モジュールが共有するドメイン型は `Sources/BlueTicker/Models/` に独立ファイルとして置く。

### 並行性

- 共有可変状態（キャッシュ・HTTP クライアント）は `actor` で排他する（`CacheManager`・`EdinetAPIClient`）
- モジュールレベルの可変グローバルは原則禁止。やむを得ない場合は `nonisolated(unsafe)` ＋ `NSLock` で直列化し、理由をコメントする

### Optional の扱い

- 抽出失敗・データ欠落は `nil` で表現する（`error-handling.md` の戻り値パターン参照）
- `try?` は外部ライブラリ境界（SwiftSoup 等）でのみ使い、自前ロジックの失敗を握りつぶさない
- 強制アンラップ（`!`）は直前の構築から非 nil が自明な場合のみ

### Any の使用を最小限に

使ってよい箇所：外部 API レスポンス（EDINET / MOF）・JSONSerialization 境界の `[String: Any]`。値の型が絞れる場合は `Any` を使わない。
