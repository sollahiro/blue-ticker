# 日付

YYYYMMDD ↔ YYYY-MM-DD のインラインスライスや独自 `DateFormatter` は禁止。`FiscalYear.swift` の `normalizeDateFormat` / `parseDateString` / `formatDateString` / `extractYearMonth` を使う。長さは `DateFormat.compactLength`（8）/ `hyphenatedLength`（10）。

EDINET 日付は UTC。`Calendar.current` を新規に使わない。

`fy_end`（YYYY-MM）だけ `edinet_fy_end` の `prefix(7)` を許す（`BltServerFacade` / `TickerDev filing`）。
