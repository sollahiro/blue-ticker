"""Swift 移植（Sources/BlueTicker/）のレイヤリング・定数パリティ検証。

Swift パッケージは単一モジュールのため import 文によるレイヤー検証ができない。
代わりに「下位レイヤーのソースが上位レイヤーで宣言された型名を参照していないこと」を
検証する（test_dependency_rules.py の Python 版ルールに対応）。

- CLI（app 相当）の型は他のすべてのレイヤーから参照禁止
- Services の型は API / Infrastructure / Utils / Constants / Models / Analysis から参照禁止

また、Xbrl.swift のタグリスト定数が Python constants/xbrl.py のいずれかの定数と
値一致することを検証し、片側だけタグを追加した際のドリフトを検知する。
"""

import re
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SWIFT_ROOT = PROJECT_ROOT / "Sources" / "BlueTicker"

_TYPE_DECL_RE = re.compile(r"\b(?:struct|class|enum|protocol|actor)\s+([A-Z]\w+)")
_LINE_COMMENT_RE = re.compile(r"//.*")
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


def _swift_files(subdir: str) -> list[Path]:
    return sorted((SWIFT_ROOT / subdir).rglob("*.swift"))


def _declared_types(subdir: str) -> set[str]:
    types: set[str] = set()
    for f in _swift_files(subdir):
        types |= set(_TYPE_DECL_RE.findall(f.read_text(encoding="utf-8")))
    return types


def _code_without_comments(f: Path) -> str:
    src = _BLOCK_COMMENT_RE.sub("", f.read_text(encoding="utf-8"))
    return _LINE_COMMENT_RE.sub("", src)


def test_swift_sources_exist():
    assert SWIFT_ROOT.is_dir()
    assert _swift_files("CLI"), "CLI レイヤーの Swift ソースが見つからない"


def test_swift_layer_direction_rules():
    cli_types = _declared_types("CLI")
    services_types = _declared_types("Services")
    assert cli_types and services_types

    rules: list[tuple[tuple[str, ...], set[str], str]] = [
        (
            ("Services", "Analysis", "API", "Infrastructure", "Utils", "Constants", "Models"),
            cli_types,
            "CLI",
        ),
        (
            ("API", "Infrastructure", "Utils", "Constants", "Models", "Analysis"),
            services_types,
            "Services",
        ),
    ]
    for layers, banned_types, banned_layer in rules:
        for layer in layers:
            for f in _swift_files(layer):
                src = _code_without_comments(f)
                for type_name in banned_types:
                    assert not re.search(rf"\b{type_name}\b", src), (
                        f"{f.relative_to(PROJECT_ROOT)}: {banned_layer} レイヤーの型 "
                        f"{type_name} を参照している（依存方向違反）"
                    )


# US-GAAP HTML 仮想タグ（USGAAP_HTML_*）等が Swift 未移植のため、
# Python 側と意図的に異なるリスト。新規の差分はここに追加せず Python に合わせること。
_KNOWN_DIVERGENCES = {
    "operatingProfitDirectTags",
    "grossProfitSalesTags",
    "grossProfitCostsTags",
    "employeeTags",
    "cashEquivalentsTags",
}


def test_swift_xbrl_tag_lists_match_python():
    import blue_ticker.constants.xbrl as python_xbrl

    swift_src = (SWIFT_ROOT / "Constants" / "Xbrl.swift").read_text(encoding="utf-8")
    swift_lists: dict[str, list[str]] = {
        name: re.findall(r'"([^"]+)"', body)
        for name, body in re.findall(
            r"static let (\w+): \[String\] = \[(.*?)\]", swift_src, re.DOTALL
        )
    }
    assert swift_lists, "Xbrl.swift からタグリスト定数を抽出できない"

    python_tuples: set[tuple[str, ...]] = set()
    python_sets: set[frozenset[str]] = set()
    for attr in dir(python_xbrl):
        if attr.startswith("_"):
            continue
        value = getattr(python_xbrl, attr)
        if isinstance(value, list) and value and all(isinstance(x, str) for x in value):
            python_tuples.add(tuple(value))
            python_sets.add(frozenset(value))
        elif isinstance(value, frozenset) and value and all(isinstance(x, str) for x in value):
            python_sets.add(frozenset(value))

    for name, tags in swift_lists.items():
        if name in _KNOWN_DIVERGENCES:
            continue
        matched = tuple(tags) in python_tuples or frozenset(tags) in python_sets
        assert matched, (
            f"Xbrl.swift の {name} が Python constants/xbrl.py のどの定数とも一致しない。"
            f"片側だけタグを追加・変更した可能性がある: {tags}"
        )
