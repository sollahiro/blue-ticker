import sys
import logging
import asyncio

from blue_ticker.constants.api import EDINET_PREPARE_DEFAULT_YEARS
from blue_ticker.infrastructure.settings import settings_store

logger = logging.getLogger(__name__)


class _DummyParser:
    """対話型モードで cmd_config に渡すダミーパーサー"""
    def print_help(self):
        pass


def cmd_config(args, parser):
    """設定管理コマンド"""
    if not args.config_subcommand:
        parser.print_help()
        return

    if args.config_subcommand == "show":
        settings = settings_store.get_masked()
        print("\n現在の設定 (機密情報はマスクされています):", file=sys.stderr)
        print("-" * 40, file=sys.stderr)
        for k, v in settings.items():
            print(f"{k:<20}: {v}", file=sys.stderr)
        print("-" * 40, file=sys.stderr)
        print(f"設定ファイルパス: {settings_store.config_path}", file=sys.stderr)

    elif args.config_subcommand == "set":
        if not args.key or args.value is None:
            print("キーと値を指定してください。例: ticker config set edinet-key YOUR_KEY", file=sys.stderr)
            return

        # マッピング（CLIからの入力をバックエンドのキー名に変換）
        key_map = {
            "edinetApiKey": "edinetApiKey",
            "edinet-key": "edinetApiKey",
            "edinetBackend": "edinetBackend",
            "edinet-backend": "edinetBackend",
        }

        raw_key: str = args.key or ""
        if raw_key not in key_map:
            allowed = ", ".join(sorted(set(key_map.values())))
            print(f"エラー: 不明な設定キー '{raw_key}'。使用可能なキー: {allowed}", file=sys.stderr)
            return
        target_key: str = key_map[raw_key]
        target_value = args.value

        if target_key == "edinetBackend" and target_value not in ("local", "remote"):
            print(f"エラー: edinet-backend の値は 'local' または 'remote' を指定してください。", file=sys.stderr)
            return

        if target_key == "edinetBackend" and target_value == "remote":
            print("注意: remote バックエンドは未対応です（Phase 3 未実装）。設定は保存しますが、動作は local と同じになります。", file=sys.stderr)

        settings_store.update({target_key: target_value}, save=True)
        print(f"設定を更新しました: {target_key} = {target_value}", file=sys.stderr)

    elif args.config_subcommand == "check":
        e_key = settings_store.edinet_api_key
        backend = settings_store.edinet_backend
        print("\nAPI設定チェック:", file=sys.stderr)
        print(f"  EDINET APIキー:   {'✅ 設定済み' if e_key else '❌ 未設定'}", file=sys.stderr)
        print(f"  EDINET バックエンド: {backend}", file=sys.stderr)
        if not e_key and backend == "local":
            print("\n未設定のキーは以下のコマンドで設定できます:", file=sys.stderr)
            print("  ticker config set edinet-key <KEY>", file=sys.stderr)

    elif args.config_subcommand == "init":
        print("\nBLUE TICKER 初期設定", file=sys.stderr)
        print("-" * 40, file=sys.stderr)
        e_key = input("EDINET APIキー (空でスキップ): ").strip()

        updates = {}
        if e_key: updates["edinetApiKey"] = e_key

        if updates:
            settings_store.update(updates, save=True)
            print("設定を保存しました。", file=sys.stderr)
            from blue_ticker.app.cli.cache import print_prepare_done, print_prepare_loading, prepare_edinet_index_async
            from blue_ticker.app.cli.ui import confirm

            if e_key and confirm(f"直近{EDINET_PREPARE_DEFAULT_YEARS}年分のEDINETキャッシュを準備しますか？ (y/N): "):
                print_prepare_loading(EDINET_PREPARE_DEFAULT_YEARS)
                data = asyncio.run(
                    prepare_edinet_index_async(
                        settings_store.edinet_api_key or e_key,
                        settings_store.cache_dir,
                        EDINET_PREPARE_DEFAULT_YEARS,
                    )
                )
                print_prepare_done(data)
        else:
            print("変更はありません。", file=sys.stderr)
