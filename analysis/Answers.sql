--Which manufacturers are making the highest payments to physicians? 

SELECT 
      m.manufacturer_name , 
      SUM(P.amount_usd) AS total_amount_usd
FROM 
    gold.fact_payment p 
LEFT JOIN 
    gold.dim_manufacturer m
ON  
    p.manufacturer_sk = m.manufacturer_sk
LEFT JOIN 
    gold.dim_recipient r
ON  
    P.recipient_sk = r.recipient_sk

WHERE 
      r.recipient_type = 'Physician'
GROUP BY 
    m.manufacturer_name , m.manufacturer_sk
ORDER BY 
    total_amount_usd DESC 
LIMIT 10 ;

--Which physicians received the highest total payments? 

SELECT
    r.recipient_npi,
    r.full_name,
    r.primary_specialty,
    r.city,
    r.state,
    count(*)                    AS payment_records,
    sum(f.payment_count)        AS payments,
    sum(f.amount_usd)           AS total_amount_usd
FROM gold.fact_payment       f
JOIN gold.lkp_recipient_type rt USING (recipient_type_sk)
JOIN gold.dim_recipient      r  USING (recipient_sk)
WHERE rt.recipient_type = 'Physician'
  AND f.recipient_sk NOT IN (-1, -2)
GROUP BY ALL
ORDER BY total_amount_usd DESC
LIMIT 20;

--What type of payment is most common? 

SELECT
    n.nature_of_payment,
    n.nature_group,
    count(*)                                                AS payment_records,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)      AS pct_of_records,
    sum(f.amount_usd)                                       AS total_amount_usd,
    round(avg(f.amount_usd), 2)                             AS avg_amount_usd
FROM gold.fact_payment f
JOIN gold.dim_nature_of_payment n USING (nature_sk)
GROUP BY ALL
ORDER BY payment_records DESC;

-- Which states have the highest payment activity?
SELECT
    coalesce(r.state, h.state)                              AS state,
    count(*)                                                AS payment_records,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)      AS pct_of_records,
    sum(f.amount_usd)                                       AS total_amount_usd,
    approx_quantile(f.amount_usd, 0.5)                      AS median_amount_usd,
    approx_count_distinct(f.recipient_sk)                   AS distinct_recipients
FROM gold.fact_payment f
LEFT JOIN gold.dim_recipient         r ON r.recipient_sk         = f.recipient_sk
LEFT JOIN gold.dim_teaching_hospital h ON h.teaching_hospital_sk = f.teaching_hospital_sk
GROUP BY 1
ORDER BY payment_records DESC
LIMIT 15;

-- What is the trend of payments over time?

SELECT
    d.year_month,
    d.month_abbr,
    count(*)                                            AS payment_records,
    sum(f.amount_usd)                                   AS total_amount_usd,
    sum(f.amount_usd) FILTER (
        WHERE n.nature_of_payment NOT IN ('Royalty or License', 'Acquisitions'))
                                                        AS amount_ex_outliers_usd,
    median(f.amount_usd)                                AS median_amount_usd,
    sum(sum(f.amount_usd)) OVER (ORDER BY d.year_month) AS cumulative_usd
FROM gold.fact_payment f
JOIN gold.dim_date              d ON d.date_key  = f.payment_date_key
JOIN gold.dim_nature_of_payment n ON n.nature_sk = f.nature_sk
WHERE f.payment_date_key <> -1
GROUP BY d.year_month, d.month_abbr
ORDER BY d.year_month;

-- Which medical specialties receive the highest payments?

SELECT
    coalesce(r.primary_specialty_area, '(not reported)')   AS specialty,
    count(*)                                               AS payment_records,
    sum(f.amount_usd)                                      AS total_amount_usd,
    count(DISTINCT f.recipient_sk)                         AS physicians_paid,
    sum(f.amount_usd) / count(DISTINCT f.recipient_sk)     AS usd_per_physician,
    median(f.amount_usd)                                   AS median_payment_usd,
    round(100 * coalesce(sum(f.amount_usd) FILTER (WHERE n.nature_of_payment = 'Royalty or License'), 0)
              / sum(f.amount_usd), 1)                      AS pct_royalty
FROM gold.fact_payment f
JOIN gold.lkp_recipient_type    rt USING (recipient_type_sk)
JOIN gold.dim_recipient         r  USING (recipient_sk)
JOIN gold.dim_nature_of_payment n  USING (nature_sk)
WHERE rt.recipient_type = 'Physician'
  AND f.recipient_sk > 0
GROUP BY ALL
ORDER BY total_amount_usd DESC      -- or usd_per_physician DESC
LIMIT 15;

--Which drugs or medical products are linked with the highest payments? 

        SELECT
    p.product_name,
    p.product_type,
    p.therapeutic_area,
    count(*)                                       AS payment_records,
    sum(f.amount_usd * b.allocation_weight)        AS allocated_amount_usd,
    sum(f.amount_usd)                              AS unallocated_amount_usd   -- only for comparison; do not report
FROM gold.fact_payment           f
JOIN gold.bridge_payment_product b ON b.record_id  = f.record_id
JOIN gold.dim_product            p ON p.product_sk = b.product_sk
WHERE b.product_sk > 0                 -- drop -1 Unknown / -2 No Product
GROUP BY ALL
ORDER BY allocated_amount_usd DESC
LIMIT 20;   

-- Which payment categories are increasing or decreasing over time?
WITH monthly AS (
    SELECT
        n.nature_of_payment,
        d.month_number,
        count(*)::DOUBLE           AS records,
        sum(f.amount_usd)::DOUBLE  AS amount_usd
    FROM gold.fact_payment f
    JOIN gold.dim_date              d ON d.date_key  = f.payment_date_key
    JOIN gold.dim_nature_of_payment n ON n.nature_sk = f.nature_sk
    WHERE f.payment_date_key <> -1
    GROUP BY ALL
),
by_nature AS (
    SELECT
        nature_of_payment,
        sum(records) FILTER (WHERE month_number <= 3)            AS q1_records,
        sum(records) FILTER (WHERE month_number >= 10)           AS q4_records,
        regr_slope(records, month_number)    / avg(records)      AS records_slope,
        regr_r2(records, month_number)                           AS records_r2,
        regr_slope(amount_usd, month_number) / nullif(avg(amount_usd), 0) AS usd_slope
    FROM monthly
    GROUP BY nature_of_payment
    HAVING count(*) >= 3          -- need a few months of data to fit a trend
)
SELECT
    nature_of_payment,
    q1_records::BIGINT                                        AS q1_records,
    q4_records::BIGINT                                        AS q4_records,
    round(100 * (q4_records / nullif(q1_records, 0) - 1), 1)  AS q4_vs_q1_pct,
    round(100 * records_slope, 1)                             AS trend_pct_per_month,
    round(records_r2, 2)                                      AS trend_r2,
    round(100 * usd_slope, 1)                                 AS usd_trend_pct_per_month
FROM by_nature
ORDER BY trend_pct_per_month DESC NULLS LAST;

