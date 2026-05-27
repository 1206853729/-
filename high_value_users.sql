-- ============================================================
-- 高价值用户画像 - 付费行为分析
-- 数据源: block-away-slide-color-master.analytics_502872665.events_intraday_*
-- 分析周期: 2026-04-01 ~ 2026-04-30
-- ============================================================

-- ============================================================
-- Part 1: 用户分层 — 计算总收入，取前 20%
-- ============================================================
WITH
revenue_raw AS (
  SELECT
    user_pseudo_id,
    event_name,
    CASE WHEN event_name = 'ad_impression'
      THEN COALESCE(
        (SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'value'), 0)
      ELSE 0
    END AS ad_revenue,
    CASE WHEN event_name = 'in_app_purchase'
      THEN COALESCE(
        (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'value'), 0) / 1000000.0
      ELSE 0
    END AS iap_raw_value,
    CASE WHEN event_name = 'in_app_purchase'
      THEN COALESCE(
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'currency'), 'USD')
      ELSE NULL
    END AS iap_currency,
    SAFE.TIMESTAMP_MICROS(
      (SELECT value.set_timestamp_micros FROM UNNEST(user_properties) WHERE key = 'first_open_time')
    ) AS first_open_utc
  FROM `block-away-slide-color-master.analytics_502872665.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260401' AND '20260430'
    AND event_name IN ('ad_impression', 'in_app_purchase')
),

user_revenue AS (
  SELECT
    user_pseudo_id,
    MIN(first_open_utc) AS first_open_utc,
    SUM(ad_revenue) AS total_ad_revenue,
    SUM(iap_raw_value *
      CASE iap_currency
        WHEN 'USD' THEN 1.0    WHEN 'EUR' THEN 1.09   WHEN 'GBP' THEN 1.26
        WHEN 'CAD' THEN 0.73   WHEN 'AUD' THEN 0.65   WHEN 'JPY' THEN 0.0067
        WHEN 'KRW' THEN 0.00067 WHEN 'CNY' THEN 0.138  WHEN 'TWD' THEN 0.031
        WHEN 'HKD' THEN 0.128  WHEN 'SGD' THEN 0.75   WHEN 'TRY' THEN 0.028
        WHEN 'INR' THEN 0.012  WHEN 'IDR' THEN 0.000062 WHEN 'THB' THEN 0.029
        WHEN 'MYR' THEN 0.23   WHEN 'PHP' THEN 0.018  WHEN 'VND' THEN 0.00004
        WHEN 'KZT' THEN 0.0021 WHEN 'CHF' THEN 1.12   WHEN 'SEK' THEN 0.097
        WHEN 'NOK' THEN 0.094  WHEN 'DKK' THEN 0.146  WHEN 'PLN' THEN 0.25
        WHEN 'MXN' THEN 0.053  WHEN 'BRL' THEN 0.18   WHEN 'RUB' THEN 0.011
        WHEN 'ZAR' THEN 0.054  WHEN 'AED' THEN 0.272  WHEN 'SAR' THEN 0.267
        ELSE 0
      END
    ) AS total_iap_revenue,
    SUM(ad_revenue) + SUM(iap_raw_value *
      CASE iap_currency
        WHEN 'USD' THEN 1.0    WHEN 'EUR' THEN 1.09   WHEN 'GBP' THEN 1.26
        WHEN 'CAD' THEN 0.73   WHEN 'AUD' THEN 0.65   WHEN 'JPY' THEN 0.0067
        WHEN 'KRW' THEN 0.00067 WHEN 'CNY' THEN 0.138  WHEN 'TWD' THEN 0.031
        WHEN 'HKD' THEN 0.128  WHEN 'SGD' THEN 0.75   WHEN 'TRY' THEN 0.028
        WHEN 'INR' THEN 0.012  WHEN 'IDR' THEN 0.000062 WHEN 'THB' THEN 0.029
        WHEN 'MYR' THEN 0.23   WHEN 'PHP' THEN 0.018  WHEN 'VND' THEN 0.00004
        WHEN 'KZT' THEN 0.0021 WHEN 'CHF' THEN 1.12   WHEN 'SEK' THEN 0.097
        WHEN 'NOK' THEN 0.094  WHEN 'DKK' THEN 0.146  WHEN 'PLN' THEN 0.25
        WHEN 'MXN' THEN 0.053  WHEN 'BRL' THEN 0.18   WHEN 'RUB' THEN 0.011
        WHEN 'ZAR' THEN 0.054  WHEN 'AED' THEN 0.272  WHEN 'SAR' THEN 0.267
        ELSE 0
      END
    ) AS total_revenue
  FROM revenue_raw
  WHERE user_pseudo_id IS NOT NULL
  GROUP BY user_pseudo_id
),

user_tier AS (
  SELECT
    *,
    NTILE(5) OVER (ORDER BY total_revenue DESC) AS revenue_quintile
  FROM user_revenue
)

SELECT * FROM user_tier;
-- revenue_quintile = 1 即为前 20% 高价值用户


-- ============================================================
-- Part 2: 高价值用户的付费详情（含关卡推断 + 复购间隔）
-- ============================================================
CREATE TEMP TABLE purchase_rhythm AS
WITH
revenue_calc AS (
  SELECT
    user_pseudo_id,
    MIN(SAFE.TIMESTAMP_MICROS(
      (SELECT value.set_timestamp_micros FROM UNNEST(user_properties) WHERE key = 'first_open_time')
    )) AS first_open_utc,
    SUM(CASE WHEN event_name = 'ad_impression'
      THEN COALESCE((SELECT value.double_value FROM UNNEST(event_params) WHERE key = 'value'), 0)
      ELSE 0 END) AS total_ad_revenue,
    SUM(CASE WHEN event_name = 'in_app_purchase'
      THEN COALESCE((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'value'), 0) / 1000000.0
        * CASE COALESCE((SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'currency'), 'USD')
            WHEN 'USD' THEN 1.0 WHEN 'EUR' THEN 1.09 WHEN 'GBP' THEN 1.26 WHEN 'CAD' THEN 0.73 WHEN 'AUD' THEN 0.65 WHEN 'JPY' THEN 0.0067 WHEN 'KRW' THEN 0.00067 WHEN 'CNY' THEN 0.138 WHEN 'TWD' THEN 0.031 WHEN 'HKD' THEN 0.128 WHEN 'SGD' THEN 0.75 WHEN 'TRY' THEN 0.028 WHEN 'INR' THEN 0.012 WHEN 'IDR' THEN 0.000062 WHEN 'THB' THEN 0.029 WHEN 'MYR' THEN 0.23 WHEN 'PHP' THEN 0.018 WHEN 'VND' THEN 0.00004 WHEN 'KZT' THEN 0.0021 WHEN 'CHF' THEN 1.12 WHEN 'SEK' THEN 0.097 WHEN 'NOK' THEN 0.094 WHEN 'DKK' THEN 0.146 WHEN 'PLN' THEN 0.25 WHEN 'MXN' THEN 0.053 WHEN 'BRL' THEN 0.18 WHEN 'RUB' THEN 0.011 WHEN 'ZAR' THEN 0.054 WHEN 'AED' THEN 0.272 WHEN 'SAR' THEN 0.267 ELSE 0 END
      ELSE 0 END) AS total_iap_revenue
  FROM `block-away-slide-color-master.analytics_502872665.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260401' AND '20260430'
    AND event_name IN ('ad_impression', 'in_app_purchase')
    AND user_pseudo_id IS NOT NULL
  GROUP BY user_pseudo_id
),

revenue_with_total AS (
  SELECT *, total_ad_revenue + total_iap_revenue AS total_revenue
  FROM revenue_calc
),

high_value_users AS (
  SELECT user_pseudo_id, total_revenue, total_ad_revenue, total_iap_revenue, first_open_utc
  FROM (
    SELECT *, NTILE(5) OVER (ORDER BY total_revenue DESC) AS revenue_quintile
    FROM revenue_with_total
  )
  WHERE revenue_quintile = 1
),

level_context AS (
  SELECT
    user_pseudo_id,
    TIMESTAMP_MICROS(event_timestamp) AS event_ts,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'level_id') AS level_id
  FROM `block-away-slide-color-master.analytics_502872665.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260401' AND '20260430'
    AND event_name = 'level_start'
    AND user_pseudo_id IN (SELECT user_pseudo_id FROM high_value_users)
),

iap_events AS (
  SELECT
    user_pseudo_id,
    TIMESTAMP_MICROS(event_timestamp) AS purchase_time,
    COALESCE(
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'value'), 0
    ) / 1000000.0 AS iap_local,
    COALESCE(
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'value'), 0
    ) / 1000000.0 *
    CASE COALESCE((SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'currency'), 'USD')
      WHEN 'USD' THEN 1.0    WHEN 'EUR' THEN 1.09   WHEN 'GBP' THEN 1.26
      WHEN 'CAD' THEN 0.73   WHEN 'AUD' THEN 0.65   WHEN 'JPY' THEN 0.0067
      WHEN 'KRW' THEN 0.00067 WHEN 'CNY' THEN 0.138  WHEN 'TWD' THEN 0.031
      WHEN 'HKD' THEN 0.128  WHEN 'SGD' THEN 0.75   WHEN 'TRY' THEN 0.028
      WHEN 'INR' THEN 0.012  WHEN 'IDR' THEN 0.000062 WHEN 'THB' THEN 0.029
      WHEN 'MYR' THEN 0.23   WHEN 'PHP' THEN 0.018  WHEN 'VND' THEN 0.00004
      WHEN 'KZT' THEN 0.0021 WHEN 'CHF' THEN 1.12   WHEN 'SEK' THEN 0.097
      WHEN 'NOK' THEN 0.094  WHEN 'DKK' THEN 0.146  WHEN 'PLN' THEN 0.25
      WHEN 'MXN' THEN 0.053  WHEN 'BRL' THEN 0.18   WHEN 'RUB' THEN 0.011
      WHEN 'ZAR' THEN 0.054  WHEN 'AED' THEN 0.272  WHEN 'SAR' THEN 0.267
      ELSE 0 END AS iap_value,
    COALESCE(
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'currency'), 'USD'
    ) AS currency,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'level_id') AS level_id_direct
  FROM `block-away-slide-color-master.analytics_502872665.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260401' AND '20260430'
    AND event_name = 'in_app_purchase'
    AND user_pseudo_id IN (SELECT user_pseudo_id FROM high_value_users)
),

closest_level AS (
  SELECT
    i.user_pseudo_id,
    i.purchase_time,
    l.level_id,
    ROW_NUMBER() OVER (
      PARTITION BY i.user_pseudo_id, i.purchase_time
      ORDER BY l.event_ts DESC
    ) AS rn
  FROM iap_events i
  JOIN level_context l
    ON l.user_pseudo_id = i.user_pseudo_id
   AND l.event_ts <= i.purchase_time
),

iap_with_level AS (
  SELECT
    i.user_pseudo_id,
    i.purchase_time,
    i.iap_local,
    i.iap_value,
    i.currency,
    COALESCE(i.level_id_direct, c.level_id) AS level_id
  FROM iap_events i
  LEFT JOIN closest_level c
    ON c.user_pseudo_id = i.user_pseudo_id
   AND c.purchase_time = i.purchase_time
   AND c.rn = 1
)

SELECT
  user_pseudo_id,
  purchase_time,
  DATE(purchase_time) AS purchase_date,
  level_id,
  iap_local,
  iap_value,
  currency,
  ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY purchase_time) AS purchase_seq,
  COUNT(*) OVER (PARTITION BY user_pseudo_id) AS total_purchases,
  MIN(purchase_time) OVER (PARTITION BY user_pseudo_id) AS first_purchase_time,
  LAG(purchase_time) OVER (PARTITION BY user_pseudo_id ORDER BY purchase_time) AS prev_purchase_time
FROM iap_with_level;

-- ====== 查询 A: 首充关卡分布 ======
SELECT
  IFNULL(level_id, '未知') AS first_purchase_level,
  COUNT(*) AS user_count,
  ROUND(AVG(iap_value), 2) AS avg_first_amount_usd
FROM purchase_rhythm
WHERE purchase_seq = 1
GROUP BY level_id
ORDER BY user_count DESC;

-- ====== 查询 B: 全量付费关卡分布 ======
SELECT
  IFNULL(level_id, '未知') AS level_id,
  COUNT(*) AS purchase_count,
  COUNT(DISTINCT user_pseudo_id) AS unique_users,
  ROUND(SUM(iap_value), 2) AS total_revenue_usd,
  ROUND(AVG(iap_value), 2) AS avg_amount_usd
FROM purchase_rhythm
GROUP BY level_id
ORDER BY purchase_count DESC;

-- ====== 查询 C: 用户付费节奏明细（人均） ======
SELECT
  user_pseudo_id,
  total_purchases AS purchase_count,
  DATE(first_purchase_time) AS first_purchase_date,
  ROUND(SUM(iap_value), 2) AS total_spent_usd,
  ROUND(AVG(DATE_DIFF(purchase_time, prev_purchase_time, DAY)), 1) AS avg_days_between,
  MIN(DATE_DIFF(purchase_time, prev_purchase_time, DAY)) AS min_days_between,
  MAX(DATE_DIFF(purchase_time, prev_purchase_time, DAY)) AS max_days_between
FROM purchase_rhythm
WHERE prev_purchase_time IS NOT NULL
GROUP BY user_pseudo_id, total_purchases, first_purchase_time
ORDER BY total_spent_usd DESC
LIMIT 100;

-- ====== 查询 D: 复购间隔整体分布 ======
SELECT
  CASE
    WHEN days_gap = 0 THEN '同日复购'
    WHEN days_gap BETWEEN 1 AND 3 THEN '1-3天'
    WHEN days_gap BETWEEN 4 AND 7 THEN '4-7天'
    WHEN days_gap BETWEEN 8 AND 14 THEN '8-14天'
    WHEN days_gap BETWEEN 15 AND 30 THEN '15-30天'
    ELSE '>30天'
  END AS interval_bucket,
  COUNT(*) AS count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
FROM (
  SELECT DATE_DIFF(purchase_time, prev_purchase_time, DAY) AS days_gap
  FROM purchase_rhythm
  WHERE prev_purchase_time IS NOT NULL
)
GROUP BY 1
ORDER BY MIN(days_gap);

-- ====== 查询 E: 用户付费频次分布 ======
SELECT
  CASE
    WHEN purchase_count = 1 THEN '仅1次'
    WHEN purchase_count = 2 THEN '2次'
    WHEN purchase_count BETWEEN 3 AND 5 THEN '3-5次'
    WHEN purchase_count BETWEEN 6 AND 10 THEN '6-10次'
    ELSE '>10次'
  END AS frequency_bucket,
  COUNT(*) AS user_count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
FROM (
  SELECT user_pseudo_id, COUNT(*) AS purchase_count
  FROM purchase_rhythm
  GROUP BY user_pseudo_id
)
GROUP BY 1
ORDER BY 1;
