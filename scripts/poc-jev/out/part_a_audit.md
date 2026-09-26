# Part A — current-year table selection audit

Universe: latest `company_filing_sections` row per code (**3801** docs), all `sections-v8` (today’s extractor). Production **SELECT** only; markdown `period` is the extractor output.

`detectPeriodFromGrid` / preceding-caption keywords are `当連結会計年度` / `当期` (and 前*). `当年度` and `fy_end` dates (`2025年度` etc.) are **not** period keywords; they only help table chaining. Unlabeled numeric tables get `applyPeriodOrdering` (first=前期, second=当期). Dedicated geography/product TextBlocks may get `contextRef` (`CurrentYearDuration` → 当期) when exactly one unlabeled numeric table is in the block.

## Counts per axis

| axis | (1) explicit HTML label | (2) heuristic | (3) tables exist, no 当期/比較 | facts-only (no HTML tables) | axis empty (`not_found`) | total |
|---|---:|---:|---:|---:|---:|---:|
| revenue_recognition | 2601 | 460 | 14 | 0 | 726 | 3801 |
| segment_info / segments | 1968 | 1430 | 16 | 146 | 241 | 3801 |
| geography | 144 | 1185 | 21 | 23 | 2428 | 3801 |

### Layout of HTML tables (prior vs current)

| axis | separate tables (前期+当期) | one table two columns (比較) | both | current only | prior only | no tables |
|---|---:|---:|---:|---:|---:|---:|
| revenue_recognition | 965 | 809 | 1103 | 184 | 13 | 726 |
| segment_info | 2317 | 287 | 749 | 45 | 13 | 387 |
| geography | 1133 | 141 | 1 | 54 | 18 | 2451 |

Revenue-recognition notes are mostly labeled in HTML (2601/3075 html_table). Geography is the opposite: 1185/1350 html_table current-year tables have **no** `当連結会計年度`/`当期` in the first rows — many are Prior/Current **separate TextBlocks** whose HTML has no period heading, so today’s code uses `contextRef` or `applyPeriodOrdering`. That is bucket (2), not (1).

`axis_empty_not_found` is **not** automatically “note exists”. Geography 2428 and RR 726 include companies with no such note. Bucket (3) is the stricter set: HTML tables were extracted but none labeled 当期/比較 (single unlabeled table becomes 前期 under `applyPeriodOrdering`).

## PoC #446 comparator (33 of 70)

Of PR #446's 70 revenue_recognition_llm needs_review docs, exactly 33 had a single table labeled 当期, so existing-code table choice was unique. The other 37 had multiple 当期 tables, only 比較 (two-column), only 前期, or mixed layouts — stored_table_index existed but was not a unique current-year table index.

Those 70 docs were `company_breakdowns` with `source=revenue_recognition_llm` AND `needs_review`. `stored_table_index` was present for 70/70; uniqueness of a 当期 table is what failed for 37.

## Sample bucket (2) and (3)

### revenue_recognition
#### bucket 2 (first 25)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 1380 | S100YK4U | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1435 | S100XSYD | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1518 | S100YBV8 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1663 | S100XUMN | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1718 | S100XTPB | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1811 | S100YJ24 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1814 | S100YK21 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1871 | S100YEO8 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1882 | S100YFHW | heuristic_year_header_unused_by_detector | separate_tables | html_table |
| 1946 | S100YIKH | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1951 | S100YI51 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2001 | S100YIC9 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2004 | S100YGEO | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2117 | S100YIPK | heuristic_year_header_unused_by_detector | separate_tables | html_table |
| 2120 | S100X8TY | heuristic_year_header_unused_by_detector | separate_tables | html_table |
| 2134 | S100W9WY | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2173 | S100XV33 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2175 | S100YF7X | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2195 | S100XRZ8 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2207 | S100YHY5 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2264 | S100YIHY | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2269 | S100YILP | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2291 | S100YHU1 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2340 | S100YMBF | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 2342 | S100YCRI | heuristic_year_header_unused_by_detector | separate_tables | html_table |

#### bucket 3 (first 14)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 2266 | S100XSYQ | tables_labeled_prior_only | prior_only | html_table |
| 2323 | S100YKRB | tables_labeled_prior_only | prior_only | html_table |
| 2768 | S100Y9EI | tables_labeled_prior_only | prior_only | html_table |
| 4976 | S100Z3JC | tables_labeled_prior_only | prior_only | html_table |
| 6635 | S100XUDS | tables_labeled_prior_only | prior_only | html_table |
| 6723 | S100XR06 | tables_labeled_prior_only | prior_only | html_table |
| 6989 | S100YJZD | no_current_period_table | unlabeled_or_other | html_table |
| 7434 | S100WLHT | tables_labeled_prior_only | prior_only | html_table |
| 8383 | S100YDT2 | tables_labeled_prior_only | prior_only | html_table |
| 8386 | S100YA4U | tables_labeled_prior_only | prior_only | html_table |
| 8772 | S100YI2V | tables_labeled_prior_only | prior_only | html_table |
| 9214 | S100XV6A | tables_labeled_prior_only | prior_only | html_table |
| 9561 | S100XV2A | tables_labeled_prior_only | prior_only | html_table |
| 9824 | S100XHVV | tables_labeled_prior_only | prior_only | html_table |

Bucket 3 full list is in `part_a_audit.json` → `bucket3_full`.

### segment_info
#### bucket 2 (first 25)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 1332 | S100YHOQ | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 135A | S100Y2CG | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1375 | S100YK0W | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1377 | S100YXUM | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1379 | S100YKAZ | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1380 | S100YK4U | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1381 | S100Z3O7 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1382 | S100WPAF | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1383 | S100XHX5 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1407 | S100X68L | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1417 | S100YG40 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1419 | S100YYFR | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1420 | S100YGLY | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1429 | S100XUQB | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1430 | S100YXXB | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1443 | S100YEE3 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1515 | S100YI8I | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1662 | S100YERU | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1718 | S100XTPB | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1719 | S100YHJP | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1723 | S100YH9O | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 173A | S100YEGK | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1764 | S100WRZI | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1768 | S100YEJU | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |
| 1777 | S100YG5D | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | xbrl_facts |

#### bucket 3 (first 16)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 215A | S100YS8Y | tables_labeled_prior_only | prior_only | xbrl_facts |
| 2370 | S100XB0H | no_current_period_table | unlabeled_or_other | xbrl_facts |
| 3440 | S100X6MC | tables_labeled_prior_only | prior_only | xbrl_facts |
| 350A | S100WXET | tables_labeled_prior_only | prior_only | xbrl_facts |
| 4378 | S100XHNB | tables_labeled_prior_only | prior_only | xbrl_facts |
| 463A | S100YYT8 | tables_labeled_prior_only | prior_only | xbrl_facts |
| 4891 | S100XVBS | no_current_period_table | unlabeled_or_other | html_table |
| 4976 | S100Z3JC | tables_labeled_prior_only | prior_only | html_table |
| 5704 | S100XSBE | no_current_period_table | unlabeled_or_other | xbrl_facts |
| 6635 | S100XUDS | tables_labeled_prior_only | prior_only | html_table |
| 7357 | S100Y7GV | tables_labeled_prior_only | prior_only | xbrl_facts |
| 7434 | S100WLHT | tables_labeled_prior_only | prior_only | html_table |
| 8383 | S100YDT2 | tables_labeled_prior_only | prior_only | html_table |
| 8772 | S100YI2V | tables_labeled_prior_only | prior_only | html_table |
| 9561 | S100XV2A | tables_labeled_prior_only | prior_only | xbrl_facts |
| 9824 | S100XHVV | tables_labeled_prior_only | prior_only | html_table |

Bucket 3 full list is in `part_a_audit.json` → `bucket3_full`.

### geography
#### bucket 2 (first 25)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 1301 | S100YE8K | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1332 | S100YHOQ | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1333 | S100YCK1 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1377 | S100YXUM | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 147A | S100W2AH | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1515 | S100YI8I | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1518 | S100YBV8 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1662 | S100YERU | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 167A | S100YHJV | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1719 | S100YHJP | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 177A | S100YB5D | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1802 | S100YITC | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1803 | S100YDXD | heuristic_unlabeled_preceding_context_or_ordering | current_only | html_table |
| 1812 | S100YGGI | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1815 | S100YGCF | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1820 | S100YEDU | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1827 | S100YHMT | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1860 | S100YG3E | heuristic_unlabeled_preceding_context_or_ordering | current_only | html_table |
| 1861 | S100YK9Q | heuristic_unlabeled_preceding_context_or_ordering | current_only | html_table |
| 1885 | S100YCGY | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1892 | S100YKW2 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1893 | S100YF3Y | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1904 | S100YIC7 | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1909 | S100W5RX | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |
| 1911 | S100XTVO | heuristic_unlabeled_preceding_context_or_ordering | separate_tables | html_table |

#### bucket 3 (first 21)

| code | doc_id | reason | layout | method |
|---|---|---|---|---|
| 1887 | S100YXXI | tables_labeled_prior_only | prior_only | html_table |
| 192A | S100YZEV | tables_labeled_prior_only | prior_only | html_table |
| 2146 | S100YKK1 | tables_labeled_prior_only | prior_only | html_table |
| 2158 | S100YGJA | tables_labeled_prior_only | prior_only | html_table |
| 2286 | S100YJI4 | tables_labeled_prior_only | prior_only | html_table |
| 2587 | S100XSOA | tables_labeled_prior_only | prior_only | html_table |
| 3416 | S100XUME | tables_labeled_prior_only | prior_only | html_table |
| 3858 | S100YDYA | no_current_period_table | unlabeled_or_other | html_table |
| 4563 | S100XTMQ | tables_labeled_prior_only | prior_only | html_table |
| 4568 | S100YEY0 | tables_labeled_prior_only | prior_only | html_table |
| 4612 | S100XU2S | tables_labeled_prior_only | prior_only | html_table |
| 4765 | S100YCOR | tables_labeled_prior_only | prior_only | html_table |
| 4889 | S100YGXR | tables_labeled_prior_only | prior_only | html_table |
| 4890 | S100YFH9 | tables_labeled_prior_only | prior_only | html_table |
| 5938 | S100YD5L | tables_labeled_prior_only | prior_only | html_table |
| 6185 | S100YIYU | no_current_period_table | unlabeled_or_other | html_table |
| 6706 | S100YH6S | tables_labeled_prior_only | prior_only | html_table |
| 7963 | S100XTH9 | no_current_period_table | unlabeled_or_other | html_table |
| 8139 | S100YJAK | tables_labeled_prior_only | prior_only | html_table |
| 9474 | S100YD65 | tables_labeled_prior_only | prior_only | html_table |
| 9612 | S100XUUG | tables_labeled_prior_only | prior_only | html_table |

Bucket 3 full list is in `part_a_audit.json` → `bucket3_full`.


## R2 GET re-extraction (187 docs, 0 download failures)

Subset used for Part B. `period_source` distinguishes explicit HTML grid labels vs unlabeled (preceding caption / contextRef / `applyPeriodOrdering` / year header).

| axis | docs | (1) explicit | (2) heuristic | (3) no 当期 table or empty | unique existing_answer |
|---|---:|---:|---:|---:|---:|
| revenue_recognition | 75 | 35 | 21 | 19 | 49 |
| segment_info | 75 | 36 | 18 | 21 | 43 |
| geography | 97 | 25 | 24 | 48 | 94 |

Notes sample (from XBRL TextBlock HTML): `lease_liabilities` mostly 比較 (two-column IFRS tables); `borrowings_schedule` separate 前期/当期 tables with explicit labels; `issued_shares_and_capital` is a single 年月日 event table (not 前期/当期) — existing_answer is that table.

