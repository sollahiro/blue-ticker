---
name: release
description: ユーザーからリリースまたは version tag の作成を依頼されたときに使う。
---

# リリース

1. `.agents/rules/versioning.md` を読み、リリース対象が main に統合済みであることを確認する。
2. macOS / Linux の CI が緑であることを確認する。ローカル test だけで tag を作らない。
3. `blueTickerVersion` を `YY.M.Micro` 規則で更新する。
4. 機能変更と分けて `chore: bump version to YY.M.Micro` として commit する。
5. 軽量 tag `vYY.M.Micro` を作成して push する。既存 tag を付け直さない。

`v*` tag 自体は deploy trigger ではない。release、main への統合、tag 操作はいずれもユーザーの明示依頼なしに行わない。
