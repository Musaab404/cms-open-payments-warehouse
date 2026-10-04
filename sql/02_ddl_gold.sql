-- =============================================================================
-- 02_ddl_gold.sql
-- CMS Open Payments — General Payments PY2025 — gold star schema tables
-- -----------------------------------------------------------------------------
-- Matches the gold tables in the modeling.db catalog.
-- Surrogate keys are deterministic hashes (gold.sk) computed in the staging
-- views, so there are no sequences or defaults. Reserved members: -1 = Unknown,
-- -2 = Not Applicable / No Product / No Travel. No foreign keys are declared.
-- Loaded by section 3 of 03_load.sql, which also needs the gold macros and the
-- v_stg_payment / v_stg_payment_product views. Idempotent (IF NOT EXISTS).
-- Usage   : duckdb -bail modeling.db < 02_ddl_gold.sql
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS gold;

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------

-- Key is the YYYYMMDD integer.
CREATE TABLE IF NOT EXISTS gold.dim_date (
    date_key                          INTEGER PRIMARY KEY,
    full_date                         DATE UNIQUE,
    day_of_month                      TINYINT,
    day_of_week_iso                   TINYINT,
    day_name                          VARCHAR NOT NULL,
    is_weekend                        BOOLEAN,
    day_of_year                       SMALLINT,
    week_of_year                      TINYINT,
    iso_week                          TINYINT,
    iso_year                          SMALLINT,
    month_number                      TINYINT,
    month_name                        VARCHAR NOT NULL,
    month_abbr                        VARCHAR NOT NULL,
    year_month                        VARCHAR NOT NULL,
    quarter_number                    TINYINT,
    quarter_name                      VARCHAR NOT NULL,
    is_month_end                      BOOLEAN,
    calendar_year                     SMALLINT
);

-- SCD1: attributes from the most recent payment.
CREATE TABLE IF NOT EXISTS gold.dim_manufacturer (
    manufacturer_sk                   BIGINT PRIMARY KEY,
    manufacturer_id                   BIGINT UNIQUE,
    manufacturer_name                 VARCHAR NOT NULL,
    manufacturer_state                VARCHAR,
    manufacturer_country              VARCHAR
);

-- SCD1: attributes from the most recent payment. For the recipient type as of
-- the payment, use lkp_recipient_type instead of recipient_type here.
CREATE TABLE IF NOT EXISTS gold.dim_recipient (
    recipient_sk                      BIGINT PRIMARY KEY,
    recipient_profile_id              BIGINT UNIQUE,
    recipient_npi                     BIGINT,
    recipient_type                    VARCHAR NOT NULL,
    first_name                        VARCHAR,
    middle_name                       VARCHAR,
    last_name                         VARCHAR,
    name_suffix                       VARCHAR,
    full_name                         VARCHAR NOT NULL,
    address_line1                     VARCHAR,
    address_line2                     VARCHAR,
    city                              VARCHAR,
    state                             VARCHAR,
    zip5                              VARCHAR,
    country                           VARCHAR,
    province                          VARCHAR,
    postal_code                       VARCHAR,
    primary_type                      VARCHAR,
    primary_specialty                 VARCHAR,
    primary_specialty_group           VARCHAR,
    primary_specialty_area            VARCHAR,
    primary_types                     VARCHAR[],
    specialties                       VARCHAR[],
    license_states                    VARCHAR[]
);

-- SCD1: attributes from the most recent payment.
CREATE TABLE IF NOT EXISTS gold.dim_teaching_hospital (
    teaching_hospital_sk              BIGINT PRIMARY KEY,
    teaching_hospital_id              BIGINT UNIQUE,
    hospital_name                     VARCHAR NOT NULL,
    hospital_ccn                      VARCHAR,
    address_line1                     VARCHAR,
    city                              VARCHAR,
    state                             VARCHAR,
    zip5                              VARCHAR
);

CREATE TABLE IF NOT EXISTS gold.dim_nature_of_payment (
    nature_sk                         BIGINT PRIMARY KEY,
    nature_of_payment                 VARCHAR NOT NULL UNIQUE,
    nature_group                      VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS gold.dim_form_of_payment (
    form_sk                           BIGINT PRIMARY KEY,
    form_of_payment                   VARCHAR NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS gold.dim_travel (
    travel_sk                         BIGINT PRIMARY KEY,
    travel_city                       VARCHAR,
    travel_state                      VARCHAR,
    travel_country                    VARCHAR,
    travel_label                      VARCHAR NOT NULL,
    UNIQUE (travel_city, travel_state, travel_country)
);

-- Junk dimension of the indicator columns.
CREATE TABLE IF NOT EXISTS gold.dim_payment_flags (
    payment_flags_sk                  BIGINT PRIMARY KEY,
    change_type                       VARCHAR,
    physician_ownership               BOOLEAN,
    third_party_payment_recipient     VARCHAR,
    charity                           BOOLEAN,
    third_party_equals_covered_recip  BOOLEAN,
    delay_in_publication              BOOLEAN,
    dispute_status                    BOOLEAN,
    related_product                   BOOLEAN
);

CREATE TABLE IF NOT EXISTS gold.dim_product (
    product_sk                        BIGINT PRIMARY KEY,
    product_type                      VARCHAR,
    product_name                      VARCHAR NOT NULL,
    therapeutic_area                  VARCHAR,
    ndc                               VARCHAR,
    pdi                               VARCHAR,
    UNIQUE (product_type, product_name)
);

-- Recipient type as of the payment.
CREATE TABLE IF NOT EXISTS gold.lkp_recipient_type (
    recipient_type_sk                 BIGINT PRIMARY KEY,
    recipient_type                    VARCHAR NOT NULL
);

-- -----------------------------------------------------------------------------
-- Bridge: products are many-to-many. One row per filled product slot, or one
-- product_sk = -2 row when the payment has no product. Weight amount_usd by
-- allocation_weight (1 / products on the record) when splitting by product.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.bridge_payment_product (
    record_id                         BIGINT NOT NULL,
    product_slot                      TINYINT NOT NULL,
    product_sk                        BIGINT NOT NULL,
    covered_indicator                 VARCHAR,
    allocation_weight                 DOUBLE NOT NULL
);

-- -----------------------------------------------------------------------------
-- Fact: one row per Record_ID, keys and measures only. The NOT NULLs are
-- intentional: a broken source record should fail the load, not be defaulted.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.fact_payment (
    record_id                         BIGINT NOT NULL,
    payment_date_key                  INTEGER NOT NULL,
    manufacturer_sk                   BIGINT NOT NULL,
    recipient_sk                      BIGINT NOT NULL,
    teaching_hospital_sk              BIGINT NOT NULL,
    recipient_type_sk                 BIGINT NOT NULL,
    nature_sk                         BIGINT NOT NULL,
    form_sk                           BIGINT NOT NULL,
    travel_sk                         BIGINT NOT NULL,
    payment_flags_sk                  BIGINT NOT NULL,
    amount_usd                        DECIMAL(18,2) NOT NULL,
    payment_count                     INTEGER NOT NULL
);
