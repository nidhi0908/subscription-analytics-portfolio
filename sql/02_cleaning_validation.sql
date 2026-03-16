-- ============================================================
-- 02_cleaning.sql
-- Purpose : Fixing data types, standardising casing & validate data.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.subscriptions_clean;

CREATE TABLE analytics.subscriptions_clean AS
SELECT
    cust_id,
    UPPER(transaction_type)           AS transaction_type,   -- standardise casing
    transaction_date::DATE            AS transaction_date,   -- text → date
    subscription_type,
    subscription_price,
    customer_gender,
    age_group,
    customer_country,
    INITCAP(referral_type)            AS referral_type       -- 'facebook' → 'Facebook'
FROM staging.subscriptions;

-- Validation Checks
-- 1. Any nulls in critical columns?

SELECT
    COUNT(*) FILTER (WHERE cust_id IS NULL)           AS null_cust_id,
    COUNT(*) FILTER (WHERE transaction_date IS NULL)  AS null_date,
    COUNT(*) FILTER (WHERE transaction_type IS NULL)  AS null_type,
    COUNT(*) FILTER (WHERE subscription_price IS NULL)AS null_price,
    COUNT(*) FILTER (WHERE customer_country IS NULL)  AS null_country
FROM analytics.subscriptions_clean;

-- 2. What transaction types exist? (should be INITIAL, UPGRADE, REDUCTION, CHURN)
SELECT transaction_type, COUNT(*) AS n
FROM analytics.subscriptions_clean
GROUP BY transaction_type
ORDER BY n DESC;

-- 3. What countries exist?
SELECT customer_country, COUNT(DISTINCT cust_id) AS customers
FROM analytics.subscriptions_clean
GROUP BY customer_country
ORDER BY customers DESC;

-- 4. Any customers with more than one CHURN event? (should be 0)
SELECT cust_id, COUNT(*) AS churn_count
FROM analytics.subscriptions_clean
WHERE transaction_type = 'CHURN'
GROUP BY cust_id
HAVING COUNT(*) > 1;

SELECT *
FROM analytics.subscriptions_clean
WHERE cust_id IN (
    SELECT cust_id
    FROM analytics.subscriptions_clean
    WHERE transaction_type = 'CHURN'
    GROUP BY cust_id
    HAVING COUNT(*) > 1
)
ORDER BY cust_id, transaction_date;

WITH churn_gaps AS (
    SELECT
        a.cust_id,
        a.transaction_date AS first_churn,
        b.transaction_date AS second_churn,
        -- Was there any activity BETWEEN the two churns?
        EXISTS (
            SELECT 1
            FROM analytics.subscriptions_clean mid
            WHERE mid.cust_id = a.cust_id
              AND mid.transaction_date > a.transaction_date
              AND mid.transaction_date < b.transaction_date
              AND mid.transaction_type != 'CHURN'
        ) AS has_activity_between
    FROM analytics.subscriptions_clean a
    JOIN analytics.subscriptions_clean b
      ON a.cust_id = b.cust_id
     AND a.transaction_type = 'CHURN'
     AND b.transaction_type = 'CHURN'
     AND b.transaction_date > a.transaction_date
)
SELECT
    has_activity_between,
    COUNT(DISTINCT cust_id) AS n_customers,
    CASE has_activity_between
        WHEN true  THEN 'Re-subscriber — keep both churns'
        WHEN false THEN 'Data error — keep only first churn'
    END AS action
FROM churn_gaps
GROUP BY has_activity_between;

-- ================================================================
-- STEP 1: Removing duplicate churns (data errors)
-- Keeping only the FIRST churn for customers who have two churns
-- with no activity between them
-- ================================================================

DELETE FROM analytics.subscriptions_clean
WHERE ctid IN (
    SELECT b.ctid                        -- ctid is PostgreSQL's internal row ID
    FROM analytics.subscriptions_clean a
    JOIN analytics.subscriptions_clean b
      ON a.cust_id = b.cust_id
     AND a.transaction_type = 'CHURN'
     AND b.transaction_type = 'CHURN'
     AND b.transaction_date > a.transaction_date  -- b is the LATER churn
    WHERE NOT EXISTS (
        -- No activity between the two churns = data error, delete the later one
        SELECT 1
        FROM analytics.subscriptions_clean mid
        WHERE mid.cust_id = a.cust_id
          AND mid.transaction_date > a.transaction_date
          AND mid.transaction_date < b.transaction_date
          AND mid.transaction_type != 'CHURN'
    )
);

-- ================================================================
-- STEP 2: Handling re-subscribers (real behaviour)
-- Assign each subscription period a lifecycle number
-- so the survival analysis treats them as separate journeys
-- ================================================================

-- First add the column
ALTER TABLE analytics.subscriptions_clean
ADD COLUMN IF NOT EXISTS lifecycle_num INT DEFAULT 1;

-- Then number each lifecycle per customer
-- Each new INITIAL after a CHURN = new lifecycle
UPDATE analytics.subscriptions_clean sc
SET lifecycle_num = sub.lifecycle_num
FROM (
    SELECT
        ctid,
        cust_id,
        transaction_date,
        SUM(CASE WHEN transaction_type = 'INITIAL' THEN 1 ELSE 0 END)
            OVER (PARTITION BY cust_id ORDER BY transaction_date
                  ROWS UNBOUNDED PRECEDING)             AS lifecycle_num
    FROM analytics.subscriptions_clean
) sub
WHERE sc.ctid = sub.ctid;

-- 1. Checking duplicate churns - should return those 39
SELECT cust_id, COUNT(*) AS churn_count
FROM analytics.subscriptions_clean
WHERE transaction_type = 'CHURN'
GROUP BY cust_id
HAVING COUNT(*) > 1;

-- 2. Re-subscribers should show lifecycle_num = 2
SELECT cust_id, lifecycle_num, transaction_type, transaction_date
FROM analytics.subscriptions_clean
WHERE cust_id IN (
    SELECT cust_id FROM analytics.subscriptions_clean
    WHERE lifecycle_num = 2
    LIM
)
ORDER BY cust_id, transaction_date;

SELECT COUNT(*) AS suspicious_records
FROM analytics.subscriptions_clean t
JOIN (
    SELECT cust_id, MIN(transaction_date) AS first_date
    FROM analytics.subscriptions_clean
    WHERE transaction_type = 'INITIAL'
    GROUP BY cust_id
) s ON t.cust_id = s.cust_id
WHERE t.transaction_date < s.first_date
  AND t.transaction_type != 'INITIAL';
