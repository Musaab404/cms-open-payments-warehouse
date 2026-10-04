-- =============================================================================
-- 03_load_gold_lookup.sql
-- CMS Open Payments — General Payments PY2025 — gold lookup load
-- -----------------------------------------------------------------------------
-- Pattern : truncate-and-reload in one transaction.
-- Note    : lkp_recipient_type is the recipient type as of the payment.
--           dim_recipient.recipient_type is SCD1 (latest payment wins) and
--           differs on about 0.4% of payments, so join the fact through
--           recipient_type_sk for as-of reporting.
-- Prereq  : 02_ddl_gold.sql, the gold macros and gold.v_stg_payment, and a
--           loaded silver.general_payments.
-- Usage   : duckdb -bail modeling.db < 03_load_gold_lookup.sql
-- =============================================================================

BEGIN TRANSACTION;

TRUNCATE gold.lkp_recipient_type;

-- 1. lkp_recipient_type ------------------------------------------------------
INSERT INTO gold.lkp_recipient_type BY NAME
SELECT -1 AS recipient_type_sk, 'Unknown' AS recipient_type;

INSERT INTO gold.lkp_recipient_type BY NAME
SELECT DISTINCT recipient_type_sk, recipient_type_std AS recipient_type
FROM gold.v_stg_payment
WHERE recipient_type_sk <> -1;

COMMIT;
