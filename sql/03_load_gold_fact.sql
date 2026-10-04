-- =============================================================================
-- 03_load_gold_fact.sql
-- CMS Open Payments — General Payments PY2025 — gold fact load
-- -----------------------------------------------------------------------------
-- Pattern : truncate-and-reload in one transaction. One row per Record_ID,
--           keys and measures only. Name and text columns stay in
--           silver.general_payments (join record_id = Record_ID).
-- Keys    : every key comes from gold.v_stg_payment, which resolves missing
--           values to the reserved members (-1 / -2), so the fact can be loaded
--           before or after the dims and still join to them.
-- Prereq  : 02_ddl_gold.sql, the gold macros and gold.v_stg_payment, and a
--           loaded silver.general_payments.
-- Usage   : duckdb -bail modeling.db < 03_load_gold_fact.sql
-- =============================================================================

SET preserve_insertion_order = false;

BEGIN TRANSACTION;

TRUNCATE gold.fact_payment;

-- 1. fact_payment ------------------------------------------------------------
-- NOT NULL on record_id / amount / payment_count is intentional: a row that
-- fails here is a broken source record and must be investigated, not defaulted.
INSERT INTO gold.fact_payment BY NAME
SELECT
    Record_ID                                                    AS record_id,
    payment_date_key,
    manufacturer_sk,
    recipient_sk,
    teaching_hospital_sk,
    recipient_type_sk,
    nature_sk,
    form_sk,
    travel_sk,
    payment_flags_sk,
    Total_Amount_of_Payment_USDollars                            AS amount_usd,
    Number_of_Payments_Included_in_Total_Amount                  AS payment_count
FROM gold.v_stg_payment;

COMMIT;

CHECKPOINT;
