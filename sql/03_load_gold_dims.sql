-- =============================================================================
-- 03_load_gold_dims.sql
-- CMS Open Payments — General Payments PY2025 — gold dimension load
-- -----------------------------------------------------------------------------
-- Pattern : truncate-and-reload in one transaction. Every dim gets its reserved
--           members first (-1 = Unknown, -2 = Not Applicable / No Product /
--           No Travel), then the rows from the staging views.
-- Keys    : surrogate keys come from gold.sk in the staging views, so a reload
--           reproduces identical keys and the fact does not need reloading.
-- Prereq  : 02_ddl_gold.sql, the gold macros and views, and a loaded
--           silver.general_payments.
-- Usage   : duckdb -bail modeling.db < 03_load_gold_dims.sql
-- =============================================================================

SET preserve_insertion_order = false;

BEGIN TRANSACTION;

-- Materialise the staging views once; every dim below reads from them.
CREATE OR REPLACE TEMP TABLE stg_payment         AS SELECT * FROM gold.v_stg_payment;
CREATE OR REPLACE TEMP TABLE stg_payment_product AS SELECT * FROM gold.v_stg_payment_product;

TRUNCATE gold.dim_date;
TRUNCATE gold.dim_manufacturer;
TRUNCATE gold.dim_recipient;
TRUNCATE gold.dim_teaching_hospital;
TRUNCATE gold.dim_product;
TRUNCATE gold.dim_nature_of_payment;
TRUNCATE gold.dim_form_of_payment;
TRUNCATE gold.dim_travel;
TRUNCATE gold.dim_payment_flags;

-- 1. dim_date ---------------------------------------------------------------
INSERT INTO gold.dim_date BY NAME
SELECT -1 AS date_key, 'Unknown' AS day_name, 'Unknown' AS month_name,
       'Unk' AS month_abbr, 'Unknown' AS year_month, 'Unknown' AS quarter_name;

INSERT INTO gold.dim_date BY NAME
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER)         AS date_key,
    d                                              AS full_date,
    dayofmonth(d)                                  AS day_of_month,
    isodow(d)                                      AS day_of_week_iso,
    dayname(d)                                     AS day_name,
    isodow(d) IN (6, 7)                            AS is_weekend,
    dayofyear(d)                                   AS day_of_year,
    (dayofyear(d) - 1) // 7 + 1                    AS week_of_year,
    weekofyear(d)                                  AS iso_week,
    isoyear(d)                                     AS iso_year,
    month(d)                                       AS month_number,
    monthname(d)                                   AS month_name,
    strftime(d, '%b')                              AS month_abbr,
    strftime(d, '%Y-%m')                           AS year_month,
    quarter(d)                                     AS quarter_number,
    'Q' || quarter(d)                              AS quarter_name,
    d = last_day(d)                                AS is_month_end,
    year(d)                                        AS calendar_year
FROM (
    SELECT CAST(range AS DATE) AS d
    FROM range(DATE '2025-01-01', DATE '2026-01-01', INTERVAL 1 DAY)
);

-- 2. dim_manufacturer -------------------------------------------------------
INSERT INTO gold.dim_manufacturer BY NAME
SELECT -1 AS manufacturer_sk, 'Unknown' AS manufacturer_name;

INSERT INTO gold.dim_manufacturer BY NAME
SELECT
    manufacturer_sk,
    Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_ID                          AS manufacturer_id,
    coalesce(Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_Name, '(Name not reported)') AS manufacturer_name,
    Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_State                       AS manufacturer_state,
    Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_Country                     AS manufacturer_country
FROM stg_payment
WHERE manufacturer_sk <> -1
QUALIFY row_number() OVER (
            PARTITION BY manufacturer_sk
            ORDER BY Date_of_Payment DESC NULLS LAST, Record_ID DESC
        ) = 1;

-- 3. dim_recipient (SCD1: most recent payment's attributes win) ------------
INSERT INTO gold.dim_recipient BY NAME
SELECT -1 AS recipient_sk, 'Unknown' AS recipient_type, 'Unknown' AS full_name
UNION ALL BY NAME
SELECT -2 AS recipient_sk, 'Not Applicable' AS recipient_type,
       'Not Applicable (teaching hospital payment)' AS full_name;

INSERT INTO gold.dim_recipient BY NAME
SELECT
    recipient_sk,
    Covered_Recipient_Profile_ID                                   AS recipient_profile_id,
    Covered_Recipient_NPI                                          AS recipient_npi,
    recipient_type_std                                             AS recipient_type,
    Covered_Recipient_First_Name                                   AS first_name,
    Covered_Recipient_Middle_Name                                  AS middle_name,
    Covered_Recipient_Last_Name                                    AS last_name,
    Covered_Recipient_Name_Suffix                                  AS name_suffix,
    coalesce(
        NULLIF(concat_ws(' ', Covered_Recipient_First_Name, Covered_Recipient_Middle_Name,
                              Covered_Recipient_Last_Name,  Covered_Recipient_Name_Suffix), ''),
        '(Name not reported)')                                     AS full_name,
    Recipient_Primary_Business_Street_Address_Line1                AS address_line1,
    Recipient_Primary_Business_Street_Address_Line2                AS address_line2,
    Recipient_City                                                 AS city,
    Recipient_State                                                AS state,
    left(Recipient_Zip_Code, 5)                                    AS zip5,
    Recipient_Country                                              AS country,
    Recipient_Province                                             AS province,
    Recipient_Postal_Code                                          AS postal_code,
    Covered_Recipient_Primary_Type_1                               AS primary_type,
    Covered_Recipient_Specialty_1                                  AS primary_specialty,
    NULLIF(trim(split_part(Covered_Recipient_Specialty_1, '|', 1)), '') AS primary_specialty_group,
    NULLIF(trim(split_part(Covered_Recipient_Specialty_1, '|', 2)), '') AS primary_specialty_area,
    list_filter([Covered_Recipient_Primary_Type_1, Covered_Recipient_Primary_Type_2,
                 Covered_Recipient_Primary_Type_3, Covered_Recipient_Primary_Type_4,
                 Covered_Recipient_Primary_Type_5, Covered_Recipient_Primary_Type_6],
                lambda x: x IS NOT NULL)                           AS primary_types,
    list_filter([Covered_Recipient_Specialty_1, Covered_Recipient_Specialty_2,
                 Covered_Recipient_Specialty_3, Covered_Recipient_Specialty_4,
                 Covered_Recipient_Specialty_5, Covered_Recipient_Specialty_6],
                lambda x: x IS NOT NULL)                           AS specialties,
    list_filter([Covered_Recipient_License_State_code1, Covered_Recipient_License_State_code2,
                 Covered_Recipient_License_State_code3, Covered_Recipient_License_State_code4,
                 Covered_Recipient_License_State_code5],
                lambda x: x IS NOT NULL)                           AS license_states
FROM stg_payment
WHERE recipient_sk NOT IN (-1, -2)
QUALIFY row_number() OVER (
            PARTITION BY recipient_sk
            ORDER BY Date_of_Payment DESC NULLS LAST, Record_ID DESC
        ) = 1;

-- 4. dim_teaching_hospital --------------------------------------------------
INSERT INTO gold.dim_teaching_hospital BY NAME
SELECT -1 AS teaching_hospital_sk, 'Unknown' AS hospital_name
UNION ALL BY NAME
SELECT -2 AS teaching_hospital_sk, 'Not Applicable (individual payment)' AS hospital_name;

INSERT INTO gold.dim_teaching_hospital BY NAME
SELECT
    teaching_hospital_sk,
    Teaching_Hospital_ID                                           AS teaching_hospital_id,
    coalesce(Teaching_Hospital_Name, '(Name not reported)')        AS hospital_name,
    Teaching_Hospital_CCN                                          AS hospital_ccn,
    Recipient_Primary_Business_Street_Address_Line1                AS address_line1,
    Recipient_City                                                 AS city,
    Recipient_State                                                AS state,
    left(Recipient_Zip_Code, 5)                                    AS zip5
FROM stg_payment
WHERE teaching_hospital_sk NOT IN (-1, -2)
QUALIFY row_number() OVER (
            PARTITION BY teaching_hospital_sk
            ORDER BY Date_of_Payment DESC NULLS LAST, Record_ID DESC
        ) = 1;

-- 5. dim_product ------------------------------------------------------------
INSERT INTO gold.dim_product BY NAME
SELECT -1 AS product_sk, 'Unknown' AS product_name
UNION ALL BY NAME
SELECT -2 AS product_sk, 'No Product Reported' AS product_name;

INSERT INTO gold.dim_product BY NAME
SELECT
    product_sk,
    product_type,
    product_name,
    mode(therapeutic_area) AS therapeutic_area,
    mode(ndc)              AS ndc,
    mode(pdi)              AS pdi
FROM stg_payment_product
GROUP BY product_sk, product_type, product_name;

-- 6. dim_nature_of_payment --------------------------------------------------
INSERT INTO gold.dim_nature_of_payment BY NAME
SELECT -1 AS nature_sk, 'Unknown' AS nature_of_payment, 'Unknown' AS nature_group;

INSERT INTO gold.dim_nature_of_payment BY NAME
SELECT DISTINCT
    nature_sk,
    Nature_of_Payment_or_Transfer_of_Value AS nature_of_payment,
    CASE
        WHEN Nature_of_Payment_or_Transfer_of_Value ILIKE '%food%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%travel%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%entertainment%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%gift%'          THEN 'Hospitality & Gifts'
        WHEN Nature_of_Payment_or_Transfer_of_Value ILIKE '%consult%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%speaker%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%faculty%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%honorari%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%compensation%'  THEN 'Services & Speaking'
        WHEN Nature_of_Payment_or_Transfer_of_Value ILIKE '%royalt%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%ownership%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%acquisition%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%debt%'          THEN 'Financial & IP'
        WHEN Nature_of_Payment_or_Transfer_of_Value ILIKE '%grant%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%education%'
          OR Nature_of_Payment_or_Transfer_of_Value ILIKE '%charit%'        THEN 'Grants & Education'
        ELSE 'Other'
    END AS nature_group
FROM stg_payment
WHERE nature_sk <> -1;

-- 7. dim_form_of_payment ----------------------------------------------------
INSERT INTO gold.dim_form_of_payment BY NAME
SELECT -1 AS form_sk, 'Unknown' AS form_of_payment;

INSERT INTO gold.dim_form_of_payment BY NAME
SELECT DISTINCT form_sk, Form_of_Payment_or_Transfer_of_Value AS form_of_payment
FROM stg_payment
WHERE form_sk <> -1;

-- 8. dim_travel -------------------------------------------------------------
INSERT INTO gold.dim_travel BY NAME
SELECT -1 AS travel_sk, 'Unknown' AS travel_label
UNION ALL BY NAME
SELECT -2 AS travel_sk, 'No Travel' AS travel_label;

INSERT INTO gold.dim_travel BY NAME
SELECT DISTINCT
    travel_sk,
    travel_city_n    AS travel_city,
    travel_state_n   AS travel_state,
    travel_country_n AS travel_country,
    concat_ws(', ', travel_city_n, travel_state_n, travel_country_n) AS travel_label
FROM stg_payment
WHERE travel_sk NOT IN (-1, -2);

-- 9. dim_payment_flags (junk) -----------------------------------------------
-- -1 is reserved for consistency; every row resolves to a real combination.
INSERT INTO gold.dim_payment_flags BY NAME
SELECT -1 AS payment_flags_sk, 'Unknown' AS change_type;

INSERT INTO gold.dim_payment_flags BY NAME
SELECT DISTINCT
    payment_flags_sk,
    Change_Type                                     AS change_type,
    Physician_Ownership_Indicator                   AS physician_ownership,
    Third_Party_Payment_Recipient_Indicator         AS third_party_payment_recipient,
    Charity_Indicator                               AS charity,
    Third_Party_Equals_Covered_Recipient_Indicator  AS third_party_equals_covered_recip,
    Delay_in_Publication_Indicator                  AS delay_in_publication,
    Dispute_Status_for_Publication                  AS dispute_status,
    Related_Product_Indicator                       AS related_product
FROM stg_payment;

DROP TABLE stg_payment;
DROP TABLE stg_payment_product;

COMMIT;

CHECKPOINT;
