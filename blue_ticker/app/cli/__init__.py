from typing import TYPE_CHECKING

from .main import main

if TYPE_CHECKING:
    from .parser import build_parser
    from .analyze import cmd_analyze
    from .summarize import cmd_summarize
    from .search import cmd_search
    from .filings import cmd_filings, cmd_filing
    from .config import cmd_config
    from blue_ticker.infrastructure.settings import settings_store

__all__ = [
    "main",
    "build_parser",
    "cmd_analyze",
    "cmd_summarize",
    "cmd_search",
    "cmd_filings",
    "cmd_filing",
    "cmd_config",
]


def __getattr__(name: str) -> object:
    if name == "main":
        from .main import main

        return main
    if name == "build_parser":
        from .parser import build_parser

        return build_parser
    if name == "cmd_analyze":
        from .analyze import cmd_analyze

        return cmd_analyze
    if name == "cmd_summarize":
        from .summarize import cmd_summarize

        return cmd_summarize
    if name == "cmd_search":
        from .search import cmd_search

        return cmd_search
    if name in {"cmd_filings", "cmd_filing"}:
        from . import filings

        return getattr(filings, name)
    if name == "cmd_inspect":
    
        return cmd_inspect
    if name == "cmd_config":
        from .config import cmd_config

        return cmd_config
    if name == "settings_store":
        from blue_ticker.infrastructure.settings import settings_store

        return settings_store
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
