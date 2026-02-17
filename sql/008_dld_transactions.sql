-- ============================================================
-- LAYER 2: DLD TRANSACTIONS
-- Source: dubaipulse.gov.ae → Transactions CSV (~976MB)
--
-- This table stores Dubai Land Department transaction records.
-- Load via: COPY bronze.dld_transactions FROM '/path/to/Transactions.csv'
--           WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
--
-- Or via Python:  python -m pipeline.layers --load-dld /path/to/Transactions.csv
-- ============================================================

SET search_path TO public, bronze, tiger;

CREATE TABLE IF NOT EXISTS bronze.dld_transactions (
    id                  BIGSERIAL PRIMARY KEY,
    transaction_id      TEXT,
    instance_date       DATE,                 -- transaction date
    trans_group_en      TEXT,                  -- 'Sales', 'Mortgage', 'Gift'
    trans_type_en       TEXT,                  -- 'Sale', 'Resale', 'Pre-Registration Sale'
    reg_type_en         TEXT,                  -- 'Ready', 'Off-plan'
    is_offplan          BOOLEAN GENERATED ALWAYS AS (reg_type_en = 'Off-plan') STORED,
    is_ready            BOOLEAN GENERATED ALWAYS AS (reg_type_en = 'Ready') STORED,
    area_name_en        TEXT,                  -- community (e.g. 'Business Bay')
    project_name_en     TEXT,                  -- project/building (e.g. 'Executive Towers')
    property_type_en    TEXT,                  -- 'Unit', 'Villa', 'Land', 'Building'
    property_sub_type_en TEXT,                 -- 'Flat', 'Villa', 'Office', 'Shop'
    property_usage_en   TEXT,                  -- 'Residential', 'Commercial'
    rooms_en            TEXT,                  -- '1 B/R', '2 B/R', 'Studio', etc.
    has_parking         BOOLEAN,
    nearest_metro_en    TEXT,
    nearest_mall_en     TEXT,
    nearest_landmark_en TEXT,
    actual_worth        NUMERIC,              -- transaction value (AED)
    meter_sale_price    NUMERIC,              -- price per sqm
    procedure_area      NUMERIC,              -- area in sqm
    no_of_buyer_broker  INTEGER,
    no_of_seller_broker INTEGER,
    master_project_en   TEXT,                  -- parent project
    raw_data            JSONB,                 -- full CSV row as JSON

    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Performance indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_dld_area ON bronze.dld_transactions (area_name_en);
CREATE INDEX IF NOT EXISTS idx_dld_project ON bronze.dld_transactions (project_name_en);
CREATE INDEX IF NOT EXISTS idx_dld_date ON bronze.dld_transactions (instance_date);
CREATE INDEX IF NOT EXISTS idx_dld_trans_group ON bronze.dld_transactions (trans_group_en);
CREATE INDEX IF NOT EXISTS idx_dld_type ON bronze.dld_transactions (property_type_en);
CREATE INDEX IF NOT EXISTS idx_dld_reg_type ON bronze.dld_transactions (reg_type_en);
CREATE INDEX IF NOT EXISTS idx_dld_worth ON bronze.dld_transactions (actual_worth);
CREATE INDEX IF NOT EXISTS idx_dld_txn_id ON bronze.dld_transactions (transaction_id);
CREATE INDEX IF NOT EXISTS idx_dld_master ON bronze.dld_transactions (master_project_en);

-- Trigram index for fuzzy project name matching
CREATE INDEX IF NOT EXISTS idx_dld_project_trgm
    ON bronze.dld_transactions USING GIN (project_name_en gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_dld_area_trgm
    ON bronze.dld_transactions USING GIN (area_name_en gin_trgm_ops);

-- ============================================================
-- Materialized view: Per-project transaction summary
-- Aggregates DLD transactions for quick lookup by project
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS bronze.dld_project_summary AS
SELECT
    area_name_en,
    project_name_en,
    master_project_en,
    COUNT(*) FILTER (WHERE trans_group_en = 'Sales')        AS total_sales,
    COUNT(*) FILTER (WHERE trans_group_en = 'Mortgage')     AS total_mortgages,
    COUNT(*) FILTER (WHERE is_offplan)                      AS offplan_sales,
    COUNT(*) FILTER (WHERE is_ready)                        AS ready_sales,
    ROUND(AVG(actual_worth) FILTER (WHERE trans_group_en = 'Sales' AND actual_worth > 0)) AS avg_sale_price,
    ROUND(AVG(meter_sale_price) FILTER (WHERE trans_group_en = 'Sales' AND meter_sale_price > 0)) AS avg_psm,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY actual_worth)
          FILTER (WHERE trans_group_en = 'Sales' AND actual_worth > 0)) AS median_sale_price,
    MIN(instance_date) FILTER (WHERE trans_group_en = 'Sales') AS first_sale,
    MAX(instance_date) FILTER (WHERE trans_group_en = 'Sales') AS last_sale,
    -- Recent trend (last 12 months)
    COUNT(*) FILTER (WHERE trans_group_en = 'Sales'
                       AND instance_date >= CURRENT_DATE - INTERVAL '12 months') AS sales_last_12m,
    ROUND(AVG(actual_worth) FILTER (WHERE trans_group_en = 'Sales'
                                      AND instance_date >= CURRENT_DATE - INTERVAL '12 months'
                                      AND actual_worth > 0)) AS avg_price_last_12m,
    ROUND(AVG(meter_sale_price) FILTER (WHERE trans_group_en = 'Sales'
                                          AND instance_date >= CURRENT_DATE - INTERVAL '12 months'
                                          AND meter_sale_price > 0)) AS avg_psm_last_12m,
    -- Mode property types
    MODE() WITHIN GROUP (ORDER BY property_type_en)    AS dominant_property_type,
    MODE() WITHIN GROUP (ORDER BY property_sub_type_en) AS dominant_sub_type,
    MODE() WITHIN GROUP (ORDER BY rooms_en)             AS dominant_room_type
FROM bronze.dld_transactions
GROUP BY area_name_en, project_name_en, master_project_en;

CREATE UNIQUE INDEX IF NOT EXISTS idx_dld_summary_pk
    ON bronze.dld_project_summary (area_name_en, project_name_en);

-- ============================================================
-- Popular name enrichment from DLD:
-- Auto-discover new popular names from DLD transactions
-- that don't exist in our project_popular_names table yet
-- ============================================================
CREATE OR REPLACE VIEW bronze.dld_unmapped_projects AS
SELECT
    t.area_name_en   AS dld_area,
    t.project_name_en AS dld_project,
    t.master_project_en AS dld_master,
    COUNT(*)          AS txn_count,
    MIN(t.instance_date) AS first_txn,
    MAX(t.instance_date) AS last_txn,
    ROUND(AVG(t.actual_worth) FILTER (WHERE t.actual_worth > 0)) AS avg_price
FROM bronze.dld_transactions t
LEFT JOIN bronze.project_popular_names ppn
    ON UPPER(TRIM(t.project_name_en)) = UPPER(TRIM(ppn.popular_name))
WHERE ppn.id IS NULL
  AND t.trans_group_en = 'Sales'
  AND t.project_name_en IS NOT NULL
  AND t.project_name_en != ''
GROUP BY t.area_name_en, t.project_name_en, t.master_project_en
HAVING COUNT(*) >= 5  -- only show projects with meaningful transaction volume
ORDER BY COUNT(*) DESC;
