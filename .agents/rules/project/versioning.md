# バージョン管理

## 番号の付け方

バージョンは `YY.M.Micro` 形式にする。

- `YY`: 西暦下2桁（例: 2026年 → `26`）
- `M`: 月。ゼロ埋めしない（5月 → `5`、`05` は使わない）
- `Micro`: 同じ月内のリリース番号。月内初回は `0`

例: 2026年5月の初回リリースは `26.5.0`。

| 変更内容 | 上げ方 | 理由 |
|---|---|---|
| 月が変わった初回リリース | `YY.M.0` | 日付ベースのリリース識別 |
| 同じ月内の追加リリース | `Micro` を +1 | derived キャッシュを確実に無効化するため |

バージョンの単一の真実源は `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion`。CLI の `--version`・MCP サーバー・derived キャッシュの `_cache_version` はすべてこの定数を参照する。したがって、同じ月内でも `Micro` を上げると derived キャッシュは再生成される。

外部取得キャッシュ（`analysis_cache/external/`）は原則としてグローバルバージョンに連動させない。TTL、取得日、外部API用の個別バージョンで管理する。

## リリース手順

バージョン更新を依頼されたら、以下のステップをすべて実行すること。

0. **バンプは機能コミットとは分離し、後続の独立コミットとして行う**
1. `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion` を更新する
2. バンプコミットを作成する（`chore: bump version to YY.M.Micro`）
3. タグを作成する（`git tag vYY.M.Micro`）
4. コミットとタグをリモートへプッシュする

```bash
git push origin main
git push origin vYY.M.Micro
```

- `git push origin main` ではタグは送られない。**タグは必ず `git push origin <tag>` で明示的にプッシュする**
- タグをプッシュすると `release.yml` が `swift build -c release` でバイナリを生成し、GitHub Release と Homebrew tap を更新する
- タグは軽量タグ（annotated 不要）で統一
- **既存タグの付け直しは禁止**。必ず新しいバージョンに上げて新タグを切ること
  - タグを付け直すと GitHub が tarball を再生成して SHA256 が変わり、Homebrew formula との checksum 不一致が発生する
- タグ後に間違いを見つけた場合もタグを削除せず、バージョンを上げて新タグを切ること

## キャッシュバージョンの埋め込み（derived キャッシュ）

derived キャッシュには `_cache_version` フィールドを埋め込み、`blueTickerVersion` と照合することで古いキャッシュの混入を防ぐ。

```swift
private let _cacheVersion = blueTickerVersion  // 例: "26.6.0"

// 保存時
dict["_cache_version"] = _cacheVersion

// 読み込み時
if let c = cached, (c["_cache_version"] as? String) == _cacheVersion {
    return c  // _cache_version を除いて返す
}
// バージョン不一致 → フォールスルーして再取得・上書き
```
