"""
smoke/update_fixtures.py — smoke_expected/*.json を実際の抽出値で更新する。

ロジック変更により値が意図的に変わった場合に実行し、データセットを更新する。

実行方法:
    poetry run python smoke/update_fixtures.py
"""
import asyncio
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


async def _main() -> None:
    cache_dir = edinet_cache_dir()
    updated = skipped = 0

    for fixture_path in sorted(FIXTURE_DIR.glob("*.json")):
        fixture: dict[str, Any] = json.loads(fixture_path.read_text(encoding="utf-8"))
        code: str = fixture["code"]
        fy_end: str = fixture["fy_end"]
        name: str = fixture.get("name", code)

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
            **actuals,
        }
        fixture_path.write_text(
            json.dumps(new_fixture, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print_table(name, fy_end, actuals)
        updated += 1

    print(f"\n{updated} updated, {skipped} skipped")


if __name__ == "__main__":
    asyncio.run(_main())
