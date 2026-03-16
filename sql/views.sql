CREATE OR REPLACE VIEW analytics.customer_summary AS
WITH first_transaction AS (
    -- Get each customer's first-ever record for their attributes
    -- (country, gender, age, channel don't change per customer)
    SELECT DISTINCT ON (cust_id)
        cust_id,
        customer_country,
        customer_gender,
        age_group,
        referral_type
    FROM analytics.subscriptions_clean
    ORDER BY cust_id, transaction_date
),
lifecycle AS (
    SELECT
        cust_id,
        MIN(transaction_date)                                       AS signup_date,
        MAX(CASE WHEN transaction_type = 'CHURN'
                 THEN transaction_date END)                         AS churn_date,
        MAX(CASE WHEN transaction_type = 'CHURN' THEN 1 ELSE 0 END) AS is_churned,
        MAX(CASE WHEN transaction_type = 'UPGRADE' THEN 1 ELSE 0 END) AS ever_upgraded,
        MAX(CASE WHEN transaction_type = 'REDUCTION' THEN 1 ELSE 0 END) AS ever_reduced,
        -- First subscription tier (at signup)
        MIN(subscription_type) FILTER (
            WHERE transaction_type = 'INITIAL')                     AS initial_tier,
        -- Latest subscription tier (most recent transaction)
        (ARRAY_AGG(subscription_type ORDER BY transaction_date DESC))[1] AS current_tier,
        -- Latest price
        (ARRAY_AGG(subscription_price ORDER BY transaction_date DESC))[1] AS current_price
    FROM analytics.subscriptions_clean
    GROUP BY cust_id
)
SELECT
    l.cust_id,
    f.customer_country,
    f.customer_gender,
    f.age_group,
    f.referral_type,
    l.signup_date,
    l.churn_date,
    l.is_churned,
    l.ever_upgraded,
    l.ever_reduced,
    l.initial_tier,
    l.current_tier,
    l.current_price,
    -- Tenure: days from signup to churn (or to end of dataset if still active)
    COALESCE(l.churn_date, '2022-12-31'::DATE) - l.signup_date AS tenure_days
FROM lifecycle l
JOIN first_transaction f ON l.cust_id = f.cust_id;

-- VIEW 2 : channel_retention
-- Q1: Which acquisition channel brings customers who stay?
--
-- Why: volume alone is misleading. A channel with 5x signups
-- but 2x churn rate is worse than a smaller, loyal channel.
-- Ranking channels by retention quality, not just headcount.


CREATE OR REPLACE VIEW analytics.channel_retention AS
SELECT
    referral_type,
    COUNT(*)                                          AS total_customers,
    SUM(is_churned)                                   AS churned_customers,
    ROUND(AVG(is_churned) * 100, 1)                  AS churn_rate_pct,
    ROUND(100 - AVG(is_churned) * 100, 1)            AS retention_rate_pct,
    ROUND(AVG(tenure_days), 0)                        AS avg_tenure_days,
    -- 6-month retention: % of customers still active at day 180
    ROUND(
        AVG(CASE WHEN tenure_days >= 180 OR is_churned = 0
                 THEN 1.0 ELSE 0.0 END) * 100, 1
    )                                                 AS retention_6month_pct,
    ROUND(AVG(current_price), 2)                      AS avg_revenue_per_customer
FROM analytics.customer_summary
GROUP BY referral_type
ORDER BY retention_6month_pct DESC;

-- VIEW 3 : churn_timing_by_country
-- Q2: At what point in the lifecycle does churn spike?
--
-- Why: knowing THAT customers churn is not actionable.
-- Knowing WHEN tells you whether it's an onboarding problem
-- (0–30 days), a value problem (90–180 days), or a long-term
-- engagement problem (365+ days). Different problem, different fix.

CREATE OR REPLACE VIEW analytics.churn_timing_by_country AS
SELECT
    customer_country,
    CASE
        WHEN tenure_days <=  30 THEN '1. 0–30 days'
        WHEN tenure_days <=  90 THEN '2. 31–90 days'
        WHEN tenure_days <= 180 THEN '3. 91–180 days'
        WHEN tenure_days <= 365 THEN '4. 181–365 days'
        ELSE                         '5. 365+ days'
    END                                               AS tenure_bucket,
    COUNT(*)                                          AS total_customers,
    SUM(is_churned)                                   AS churned,
    ROUND(AVG(is_churned) * 100, 1)                  AS churn_rate_pct
FROM analytics.customer_summary
GROUP BY customer_country, tenure_bucket
ORDER BY customer_country, tenure_bucket;

-- ============================================================
-- VIEW 4 : net_revenue_by_country
-- Q3: Which country has the healthiest revenue trajectory?
--
-- Why: churn rate alone misses the revenue picture. A country
-- can have low churn but lots of reductions and still be
-- shrinking in value. We calculate monthly net MRR movement:
--   + new signups
--   + upgrades (price increase)
--   - reductions (price decrease)
--   - churns (full price lost)
-- ============================================================
CREATE OR REPLACE VIEW analytics.net_revenue_by_country AS
WITH monthly_events AS (
    SELECT
        customer_country,
        DATE_TRUNC('month', transaction_date)::DATE   AS month,
        transaction_type,
        subscription_price,
        -- For upgrades/reductions we need the price CHANGE, not full price
        -- We get previous price by looking at the prior transaction for that customer
        LAG(subscription_price) OVER (
            PARTITION BY cust_id ORDER BY transaction_date
        )                                             AS prev_price
    FROM analytics.subscriptions_clean
)
SELECT
    customer_country,
    month,
    -- New revenue from signups
    ROUND(SUM(CASE WHEN transaction_type = 'INITIAL'
                   THEN subscription_price ELSE 0 END), 2)   AS new_mrr,
    -- Revenue gained from upgrades
    ROUND(SUM(CASE WHEN transaction_type = 'UPGRADE'
                   THEN subscription_price - COALESCE(prev_price, 0)
                   ELSE 0 END), 2)                            AS expansion_mrr,
    -- Revenue lost from reductions
    ROUND(SUM(CASE WHEN transaction_type = 'REDUCTION'
                   THEN prev_price - subscription_price
                   ELSE 0 END), 2)                            AS contraction_mrr,
    -- Revenue lost from churns
    ROUND(SUM(CASE WHEN transaction_type = 'CHURN'
                   THEN subscription_price ELSE 0 END), 2)   AS churned_mrr,
    -- Net MRR movement = new + expansion - contraction - churned
    ROUND(
        SUM(CASE WHEN transaction_type = 'INITIAL'
                 THEN subscription_price ELSE 0 END)
      + SUM(CASE WHEN transaction_type = 'UPGRADE'
                 THEN subscription_price - COALESCE(prev_price, 0) ELSE 0 END)
      - SUM(CASE WHEN transaction_type = 'REDUCTION'
                 THEN prev_price - subscription_price ELSE 0 END)
      - SUM(CASE WHEN transaction_type = 'CHURN'
                 THEN subscription_price ELSE 0 END)
    , 2)                                                      AS net_mrr_movement
FROM monthly_events
GROUP BY customer_country, month
ORDER BY customer_country, month;

-- ============================================================
-- VIEW 5 : tier_transitions
-- Q4: Are customers upgrading or downgrading over time?
--     And do upgraders stay longer?
--
-- Why: the upgrade signal is the strongest indicator of
-- product-market fit. If customers are willing to pay more,
-- the product is delivering value. If reductions are rising,
-- something is wrong before churn even happens.
-- ============================================================
 
CREATE OR REPLACE VIEW analytics.tier_transitions AS
SELECT
    DATE_TRUNC('month', transaction_date)::DATE   AS month,
    transaction_type,
    COUNT(*)                                       AS n_transactions,
    ROUND(AVG(subscription_price), 2)             AS avg_price
FROM analytics.subscriptions_clean
WHERE transaction_type IN ('UPGRADE', 'REDUCTION', 'CHURN')
GROUP BY DATE_TRUNC('month', transaction_date), transaction_type
ORDER BY month, transaction_type;

-- Companion query: do upgraders stay longer?
-- Run this separately in Python to feed the box plot
CREATE OR REPLACE VIEW analytics.upgrader_tenure AS
SELECT
    CASE
        WHEN ever_upgraded = 1 AND ever_reduced = 0 THEN 'Upgraded only'
        WHEN ever_upgraded = 0 AND ever_reduced = 1 THEN 'Reduced only'
        WHEN ever_upgraded = 1 AND ever_reduced = 1 THEN 'Both'
        ELSE 'No change'
    END                                            AS customer_type,
    COUNT(*)                                       AS n_customers,
    ROUND(AVG(tenure_days), 0)                    AS avg_tenure_days,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
          (ORDER BY tenure_days)::NUMERIC, 0)     AS median_tenure_days,
    ROUND(AVG(is_churned) * 100, 1)              AS churn_rate_pct
FROM analytics.customer_summary
GROUP BY customer_type
ORDER BY avg_tenure_days DESC;

-- ============================================================
-- VIEW 6 : cohort_retention
-- Q5: Are newer cohorts retaining better than older ones?
--
-- Why: this is the single best signal of whether the product
-- is improving over time. If 2022 cohorts retain better at
-- 6 months than 2020 cohorts did, the business is getting
-- healthier. If not, growth is masking a deeper problem.
-- ============================================================
 
CREATE OR REPLACE VIEW analytics.cohort_retention AS
WITH cohorts AS (
    SELECT
        cust_id,
        DATE_TRUNC('month', signup_date)::DATE    AS cohort_month,
        tenure_days,
        is_churned
    FROM analytics.customer_summary
)
SELECT
    cohort_month,
    COUNT(*)                                                        AS cohort_size,
    -- Retention at each milestone: % still active at that point
    ROUND(AVG(CASE WHEN tenure_days >= 30  OR is_churned = 0
                   THEN 1.0 ELSE 0.0 END) * 100, 1)               AS retention_1month,
    ROUND(AVG(CASE WHEN tenure_days >= 90  OR is_churned = 0
                   THEN 1.0 ELSE 0.0 END) * 100, 1)               AS retention_3month,
    ROUND(AVG(CASE WHEN tenure_days >= 180 OR is_churned = 0
                   THEN 1.0 ELSE 0.0 END) * 100, 1)               AS retention_6month,
    ROUND(AVG(CASE WHEN tenure_days >= 365 OR is_churned = 0
                   THEN 1.0 ELSE 0.0 END) * 100, 1)               AS retention_12month
FROM cohorts
GROUP BY cohort_month
ORDER BY cohort_month;