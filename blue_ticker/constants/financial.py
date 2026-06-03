"""財務計算単位定数"""

PERCENT     = 100        # 比率→パーセント変換乗数（ROE, ROIC, 配当性向等）
MILLION_YEN = 1_000_000  # 百万円換算

# BPS候補タグのうち、分類上は比率に見えるタグが1株当たり円単位で使われた
# 場合だけ採用するための下限値。0.x は自己資本比率として扱う。
BPS_PER_SHARE_MIN_VALUE = 1.0

# NOPAT 計算用定数
NOPAT_FALLBACK_TAX_RATE  = 0.35  # 異常税率時フォールバック（35%）
NOPAT_MIN_NORMAL_TAX_RATE = 0.0  # 正常税率の下限
NOPAT_MAX_NORMAL_TAX_RATE = 0.5  # 正常税率の上限（50%）

# BPS 株式分割補正の許容相対誤差
BPS_SPLIT_ADJUSTMENT_REL_TOLERANCE = 0.01
