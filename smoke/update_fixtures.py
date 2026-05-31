"""
smoke/update_fixtures.py — smoke_expected/*.json を実際の抽出値で更新する。

ロジック変更により値が意図的に変わった場合に実行し、フィクスチャを更新する。
更新後は .checksums.json も自動的に更新される。

実行方法:
    poetry run python smoke/update_fixtures.py --ticker 2802         # 1社のみ
    poetry run python smoke/update_fixtures.py --ticker 2802 8316   # 複数指定
    poetry run python smoke/update_fixtures.py --all                 # 全件（明示的に一括更新）
"""
import argparse
import asyncio
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent.parent))

from _common import (
    FIXTURE_DIR,
    edinet_cache_dir,
    extract_actuals,
    fmt,
    print_table,
)

_CHECKSUM_FILE = FIXTURE_DIR / ".checksums.json"
_EXCLUDED_KEYS = {"_debug"}


def _load_checksums() -> dict[str, str]:
    if _CHECKSUM_FILE.exists():
        data = json.loads(_CHECKSUM_FILE.read_text(encoding="utf-8"))
        return {k: v for k, v in data.items() if not k.startswith("_")}
    return {}


def _save_checksums(checksums: dict[str, str]) -> None:
    out: dict[str, Any] = {
        "_note": "SHA-256 of each fixture file. Managed by update_fixtures.py — do not edit manually.",
    }
    out.update(checksums)
    _CHECKSUM_FILE.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


async def _main() -> None:
    parser = argparse.ArgumentParser(description="update smoke fixtures")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--ticker", nargs="+", metavar="XXXX", help="更新する銘柄コード（スペース区切りで複数指定可）")
    group.add_argument("--all", action="store_true", help="全フィクスチャを一括更新")
    args = parser.parse_args()

    cache_dir = edinet_cache_dir()
    checksums = _load_checksums()
    updated = skipped = 0

    for fixture_path in sorted(f for f in FIXTURE_DIR.glob("*.json") if not f.name.startswith(".")):
        fixture: dict[str, Any] = json.loads(fixture_path.read_text(encoding="utf-8"))
        code: str = fixture["code"]
        fy_end: str = fixture["fy_end"]
        name: str = fixture.get("name", code)

        if not args.all and code not in (args.ticker or []):
            continue

        actuals = await extract_actuals(code, fy_end, cache_dir)
        if actuals is None:
            print(f"\nSKIP  {code} {name} ({fy_end}): キャッシュなし")
            skipped += 1
            continue

        new_fixture: dict[str, Any] = {
            "_comment": "金額は円単位。effective_tax_rate は比率（例: 0.254 = 25.4%）。",
            "code": code,
            "name": name,
            "fy_end": fy_end,
            **{k: v for k, v in actuals.items() if k not in _EXCLUDED_KEYS},
        }
        fixture_path.write_text(
            json.dumps(new_fixture, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        checksums[fixture_path.name] = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
        print_table(name, fy_end, actuals)
        updated += 1

    _save_checksums(checksums)
    print(f"\n{updated} updated, {skipped} skipped")


if __name__ == "__main__":
    asyncio.run(_main())
