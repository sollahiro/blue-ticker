import ast
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_ROOT = PROJECT_ROOT / "blue_ticker"


def _iter_imports(py_file: Path):
    tree = ast.parse(py_file.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                yield node.module


def test_no_backend_import_in_blue_ticker():
    for py_file in PACKAGE_ROOT.rglob("*.py"):
        for module in _iter_imports(py_file):
            assert not module.startswith("backend"), f"{py_file}: {module}"


def test_settings_importable_without_banned_libs():
    """keyring / PyYAML なしで settings モジュールがインポートできること。"""
    import sys
    for mod in ("keyring", "yaml"):
        sys.modules.pop(mod, None)
        sys.modules[mod] = None  # import 禁止

    try:
        # キャッシュを破棄して再インポート
        for key in list(sys.modules):
            if key.startswith("blue_ticker.infrastructure.settings") or key.startswith("blue_ticker.infrastructure.keystore"):
                del sys.modules[key]
        import blue_ticker.infrastructure.settings  # noqa: F401
    finally:
        for mod in ("keyring", "yaml"):
            sys.modules.pop(mod, None)


def test_layer_direction_rules():
    for py_file in (PACKAGE_ROOT / "services").rglob("*.py"):
        for module in _iter_imports(py_file):
            assert not module.startswith("blue_ticker.app"), f"{py_file}: {module}"

    for py_file in (PACKAGE_ROOT / "infrastructure").rglob("*.py"):
        for module in _iter_imports(py_file):
            assert not module.startswith("blue_ticker.app"), f"{py_file}: {module}"
            assert not module.startswith("blue_ticker.services"), f"{py_file}: {module}"

    for py_file in (PACKAGE_ROOT / "utils").rglob("*.py"):
        for module in _iter_imports(py_file):
            assert not module.startswith("blue_ticker.app"), f"{py_file}: {module}"
            assert not module.startswith("blue_ticker.services"), f"{py_file}: {module}"

    for py_file in (PACKAGE_ROOT / "mcp_server").rglob("*.py"):
        for module in _iter_imports(py_file):
            assert not module.startswith("blue_ticker.app"), f"{py_file}: {module}"

    for layer in ("app", "services", "infrastructure", "utils"):
        for py_file in (PACKAGE_ROOT / layer).rglob("*.py"):
            for module in _iter_imports(py_file):
                assert not module.startswith("blue_ticker.mcp_server"), f"{py_file}: {module}"
