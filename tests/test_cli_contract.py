from blue_ticker.app.cli import build_parser


def test_cli_contract_subcommands_exist():
    parser = build_parser()
    subparsers_action = next(
        action for action in parser._actions if action.__class__.__name__ == "_SubParsersAction"
    )
    commands = set(subparsers_action.choices.keys())
    assert {
        "search",
        "summarize",
        "analyze",
        "config",
        "cache",
        "filings",
        "filing",
        "sector",
    }.issubset(commands)
    assert "mcp" not in commands


def test_cli_contract_uses_new_program_name():
    parser = build_parser()
    assert parser.prog == "ticker"
