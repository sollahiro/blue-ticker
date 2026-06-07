# 型アノテーション規約

Python 3.11+ を前提とする。`from __future__ import annotations` は使わない。

## pyrightに任せること

以下は pyright が自動検知する。コードレビューでは指摘しない：

- `Optional[X]` → `X | None`、`List[X]` → `list[X]` 等の旧記法
- `typing` からの `Callable`・`Mapping` 等（`collections.abc` を使う）
- 戻り値型の欠落
- `None` を含む値の未ガード演算
- TypedDict / dict 間の invariance 違反

実行: `poetry run pyright blue_ticker/`（CI でも同じコマンドを実行）。エラーを残したまま完了扱いにしない。`cast` や `Any` で消すのは外部ライブラリ境界に限定する。

## 設計ガイダンス（pyrightが検知しない）

### TypedDict と dataclass の使い分け

| ケース | 使うもの |
|---|---|
| JSON / キャッシュ / レイヤー間 dict | `TypedDict` |
| ロジックを持つオブジェクト | `dataclass` |
| 一時的な戻り値（2〜3フィールド） | `tuple[X, Y]` |

複数モジュールが共有するドメイン TypedDict は `blue_ticker/utils/` に独立ファイルとして置く。

### 読み取り専用の引数は Mapping / Sequence

`list` は invariant なので `list[TypedDict]` を `list[dict[str, Any]]` に渡せない。読み取り専用なら `Sequence[T]` / `Mapping[str, Any]` を使う（pyright がエラーで気づかせてくれる）。

### 段階的に組み立てる辞書には total=False

```python
class CalculatedData(TypedDict, total=False):  # 逐次追加
    Sales: float | None

class YearEntry(TypedDict):  # 常に全フィールドが揃う
    fy_end: str | None
    CalculatedData: CalculatedData
```

`total=False` / `NotRequired` のキーは `.get()` で読む。

### Any の使用を最小限に

使ってよい箇所：外部 API レスポンス（EDINET / MOF）の `dict[str, Any]`、全型を動的に処理する検証関数の引数。値が `float | None` 等に絞れる場合は `Any` を使わない。
