import logging
from pathlib import Path
from blue_ticker.infrastructure import keystore
from blue_ticker.infrastructure.user_paths import default_user_data_path
from typing import Any

logger = logging.getLogger(__name__)

KEYCHAIN_SERVICE = "blue-ticker"



class SettingsStore:
    """
    設定ストア（メモリ上で設定を保持）
    
    CLI の起動時または設定変更時に、
    設定値（APIキー等）を保持します。
    また、起動時にファイル（config.json）から以前の設定を読み込みます。
    """
    
    def _get_default_user_data_path(self) -> Path:
        """プラットフォームに応じたデフォルトのユーザーデータパスを返します。"""
        return default_user_data_path()

    def __init__(self):
        # ユーザーデータパスの決定
        self.user_data_path = self._get_default_user_data_path()
        
        cache_dir = self.user_data_path / "analysis_cache"

        self.user_data_path.mkdir(parents=True, exist_ok=True)
        cache_dir.mkdir(exist_ok=True)
        
        logger.info(f"Using persistent storage at: {self.user_data_path}")

        self._settings: dict[str, Any] = {
            "edinetApiKey": "",
            "cacheDir": str(cache_dir),
            "cacheEnabled": True,
            "edinetBackend": "local",
        }
        
        self.config_path = self.user_data_path / "config.json"
        
        # ファイルから既存の設定をロード
        self._load_from_file(self.config_path)
        
        logger.info(f"Initialized SettingsStore with config: {self.config_path}")

    def _load_from_file(self, config_path: Path) -> None:
        """
        CLI や設定変更で作成される config.json から設定を読み込みます。
        """
        if not config_path.exists():
            logger.info(f"Config file not found at {config_path}. Using defaults.")
            return

        try:
            import json
            with open(config_path, 'r', encoding='utf-8') as f:
                config_data = json.load(f)
                
            for key in ["edinetApiKey"]:
                if key in config_data:
                    self._settings[key] = config_data[key]

            if "edinetBackend" in config_data:
                val = config_data["edinetBackend"]
                if val in ("local", "remote"):
                    self._settings["edinetBackend"] = val
                else:
                    logger.warning(f"edinetBackend の値が不正です ({val!r})。デフォルト値 'local' を使用します。")

            if "cacheEnabled" in config_data:
                val = config_data["cacheEnabled"]
                if isinstance(val, bool):
                    self._settings["cacheEnabled"] = val
                else:
                    logger.warning(f"cacheEnabled の値が不正です ({val!r})。デフォルト値 {self._settings['cacheEnabled']} を使用します。")
            
            logger.info(f"Loaded persistent settings from {config_path}")
        except Exception as e:
            try:
                backup_path = config_path.with_suffix(".json.bak")
                config_path.rename(backup_path)
                logger.warning(f"設定ファイルが破損しています。バックアップを作成しました: {backup_path}")
            except Exception:
                pass
            logger.error(f"Failed to load settings from {config_path}: {e}")
    
    def save(self) -> bool:
        """
        現在の設定を config.json に保存します（CLIモード用）。
        APIキーはキーチェーンに保存されるため、ここには保存しません（またはマスクします）。
        """
        try:
            import json
            # 保存対象から機密情報を除外または整理
            save_data = self._settings.copy()
            
            # APIキーは空文字にしておく（キーチェーン優先のため）
            save_data["edinetApiKey"] = ""
            # 保存対象フィールドを明示（不要フィールドの混入を防ぐ）
            save_data = {k: save_data[k] for k in ("cacheDir", "cacheEnabled", "edinetBackend") if k in save_data}

            with open(self.config_path, 'w', encoding='utf-8') as f:
                json.dump(save_data, f, indent=2, ensure_ascii=False)
            return True
        except Exception as e:
            logger.error(f"Failed to save settings to {self.config_path}: {e}")
            return False

    def update(self, settings: dict[str, Any], save: bool = False) -> None:
        """
        設定を一括更新します。
        
        Args:
            settings: 更新する設定の辞書
            save: ファイルに即座に保存するか（CLI利用時など）
        """
        # APIキーが含まれている場合はキーチェーンに保存
        for key in ["edinetApiKey"]:
            if settings.get(key):
                try:
                    keystore.set_password(KEYCHAIN_SERVICE, key, settings[key])
                    # メモリ上の値は空にして、取得時にキーチェーンを参照させる
                    self._settings[key] = ""
                except Exception as e:
                    logger.error(f"Failed to save {key} to keychain: {e}")
        
        # その他の設定を更新
        self._settings.update({k: v for k, v in settings.items() if k not in ["edinetApiKey"]})
        
        if save:
            self.save()
    
    def get(self, key: str, default: Any = None) -> Any:
        """
        指定されたキーの設定値を取得します。
        
        Args:
            key: 設定キー
            default: キーが存在しない場合のデフォルト値
            
        Returns:
            設定値
        """
        # APIキーの場合はキーチェーンから取得を試みる
        if key in ["edinetApiKey"]:
            val = self._get_secret(key)
            if val:
                return val
                
        return self._settings.get(key, default)
    
    def get_all(self) -> dict[str, Any]:
        """
        全設定のコピーを取得します。
        
        Returns:
            全設定の辞書
        """
        settings = self._settings.copy()

        # キーチェーンから値を上書き
        for key in ["edinetApiKey"]:
            val = self._get_secret(key)
            if val:
                settings[key] = val

        return settings
    
    def get_masked(self) -> dict[str, Any]:
        """
        APIキーなどの機密情報をマスクした状態で全設定を取得します。
        ログ出力やフロントエンドへの返却に使用します。
        
        Returns:
            マスク済みの設定辞書
        """
        all_settings = self.get_all()
        masked = {}
        for key, value in all_settings.items():
            if 'key' in key.lower() or 'api' in key.lower():
                if value and isinstance(value, str):
                    masked[key] = value[:4] + "****" + value[-4:] if len(value) > 8 else "****"
                else:
                    masked[key] = "****" if value else None
            else:
                masked[key] = value
        return masked
    
    @property
    def edinet_api_key(self) -> str | None:
        """EDINET APIキーを取得"""
        value = self._get_secret("edinetApiKey")
        if value:
            return value
        return self._settings.get("edinetApiKey")

    def _get_secret(self, key: str) -> str | None:
        try:
            value = keystore.get_password(KEYCHAIN_SERVICE, key)
            if value:
                return value
        except Exception as e:
            logger.debug(f"Keychain access error for {key}: {e}")

        return None
    
    @property
    def cache_dir(self) -> str:
        return self._settings.get("cacheDir", "cache")

    @property
    def cache_enabled(self) -> bool:
        return self._settings.get("cacheEnabled", True)

    @property
    def edinet_backend(self) -> str:
        """EDINET バックエンド種別。"local"（直接アクセス）または "remote"（blt-server 経由）。"""
        return self._settings.get("edinetBackend", "local")


# グローバル設定インスタンス
settings_store = SettingsStore()
