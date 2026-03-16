WITH first_transaction AS (
    -- Getting each customer's first-ever record for their attributes
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
        MIN(CASE WHEN transaction_type = 'CHURN'
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