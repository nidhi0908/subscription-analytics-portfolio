CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE staging.subscriptions (
    cust_id            INT,
    transaction_type   VARCHAR(50),
    transaction_date   VARCHAR(20),   -- kept as text intentionally, cast later
    subscription_type  VARCHAR(20),
    subscription_price DECIMAL(10,2),
    customer_gender    VARCHAR(20),
    age_group          VARCHAR(20),
    customer_country   VARCHAR(50),
    referral_type      VARCHAR(50)
);