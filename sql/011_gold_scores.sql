-- ============================================================
-- LAYERS 7+8+10: SUPPLY ENGINE + TRANSFORMATION + TRUTH LAYER
--
-- Layer 7:  Supply shock engine — pipeline vs existing inventory
-- Layer 8:  Transformation score — how much will the area change?
-- Layer 10: Truth layer — DLD ↔ GIS cross-validation
-- ============================================================

SET search_path TO public, bronze, layers, gold, tiger;

-- ============================================================
-- LAYER 7: SUPPLY PIPELINE
-- Computed from DDA plots data: how much new supply is coming
-- per project, and what's the absorption risk?
-- ============================================================
CREATE TABLE IF NOT EXISTS gold.supply_pipeline (
    project_name            TEXT PRIMARY KEY,
    -- Existing inventory
    existing_units          INTEGER DEFAULT 0,
    built_plots             INTEGER DEFAULT 0,
    -- Pipeline
    approved_plots          INTEGER DEFAULT 0,
    under_construction      INTEGER DEFAULT 0,
    vacant_zoned            INTEGER DEFAULT 0,
    confirmed_pipeline      INTEGER DEFAULT 0,   -- approved + under_construction units
    potential_pipeline       INTEGER DEFAULT 0,   -- vacant_zoned units
    total_pipeline          INTEGER DEFAULT 0,
    -- Ratios
    supply_increase_pct     NUMERIC,              -- pipeline as % of existing
    -- Absorption
    estimated_absorption_months INTEGER,           -- months to absorb at ~300 units/month
    oversupply_risk_years   NUMERIC,
    -- Timing
    updated_at              TIMESTAMPTZ DEFAULT now()
);

-- Compute supply pipeline from dda_plots
INSERT INTO gold.supply_pipeline (
    project_name,
    existing_units, built_plots,
    approved_plots, under_construction, vacant_zoned,
    confirmed_pipeline, potential_pipeline, total_pipeline,
    supply_increase_pct,
    estimated_absorption_months, oversupply_risk_years
)
SELECT
    p.project_name,

    -- Existing
    COALESCE(SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'BUILT'), 0),
    COUNT(*) FILTER (WHERE p.plot_status = 'BUILT'),

    -- Pipeline breakdown
    COUNT(*) FILTER (WHERE p.plot_status = 'APPROVED'),
    COUNT(*) FILTER (WHERE p.plot_status = 'UNDER_CONSTRUCTION'),
    COUNT(*) FILTER (WHERE p.plot_status = 'VACANT_ZONED'),

    -- Confirmed pipeline (approved + under construction)
    COALESCE(SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION')), 0),
    -- Potential pipeline (vacant zoned)
    COALESCE(SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'VACANT_ZONED'), 0),
    -- Total
    COALESCE(SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION', 'VACANT_ZONED')), 0),

    -- Supply increase %
    CASE
        WHEN SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'BUILT') > 0
        THEN ROUND(
            100.0 * SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION', 'VACANT_ZONED'))
            / SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'BUILT'),
            1
        )
        ELSE NULL
    END,

    -- Absorption estimate (Dubai avg ~300 units/month per major community)
    CASE
        WHEN SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION')) > 0
        THEN CEIL(SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION'))::numeric / 300)
        ELSE 0
    END,

    -- Oversupply risk in years
    CASE
        WHEN SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'BUILT') > 0
             AND SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION')) > 0
        THEN ROUND(
            SUM(p.estimated_units) FILTER (WHERE p.plot_status IN ('APPROVED', 'UNDER_CONSTRUCTION'))::numeric
            / GREATEST(SUM(p.estimated_units) FILTER (WHERE p.plot_status = 'BUILT') * 0.05, 1),
            1
        )
        ELSE 0
    END

FROM bronze.dda_plots p
WHERE p.project_name IS NOT NULL
GROUP BY p.project_name
ON CONFLICT (project_name) DO UPDATE SET
    existing_units = EXCLUDED.existing_units,
    built_plots = EXCLUDED.built_plots,
    approved_plots = EXCLUDED.approved_plots,
    under_construction = EXCLUDED.under_construction,
    vacant_zoned = EXCLUDED.vacant_zoned,
    confirmed_pipeline = EXCLUDED.confirmed_pipeline,
    potential_pipeline = EXCLUDED.potential_pipeline,
    total_pipeline = EXCLUDED.total_pipeline,
    supply_increase_pct = EXCLUDED.supply_increase_pct,
    estimated_absorption_months = EXCLUDED.estimated_absorption_months,
    oversupply_risk_years = EXCLUDED.oversupply_risk_years,
    updated_at = now();

-- ============================================================
-- LAYER 8: TRANSFORMATION SCORE
-- How much will this area change in 3/5/10 years?
-- Combines: construction activity + infrastructure + supply change
--
-- Score breakdown:
--   Construction intensity (30%): how much is being built nearby
--   Infrastructure score   (40%): planned projects within 2km
--   Supply change          (30%): pipeline as % of existing
-- ============================================================

CREATE TABLE IF NOT EXISTS gold.transformation_score (
    plot_number             TEXT PRIMARY KEY,
    -- Component scores (0-100)
    construction_intensity  INTEGER,
    infrastructure_score    INTEGER,
    supply_change_score     INTEGER,
    -- Composite
    transformation_score    INTEGER,
    transformation_label    TEXT,    -- MASSIVE CHANGE | SIGNIFICANT | MODERATE | STABLE | STATIC
    implication             TEXT,    -- human-readable buyer guidance
    updated_at              TIMESTAMPTZ DEFAULT now()
);

-- Compute transformation scores
INSERT INTO gold.transformation_score (
    plot_number, construction_intensity, infrastructure_score,
    supply_change_score, transformation_score, transformation_label, implication
)
SELECT
    p.plot_number,

    -- Construction intensity: plots under construction within 1km (×10, capped at 100)
    LEAST(100, (
        SELECT COUNT(*) * 10 FROM bronze.dda_plots bp
        WHERE bp.plot_status IN ('UNDER_CONSTRUCTION', 'APPROVED')
          AND bp.id != p.id
          AND ST_DWithin(p.centroid::geography, bp.centroid::geography, 1000)
    )),

    -- Infrastructure: planned projects within 2km
    -- under_construction=25, planning=15, announced=10
    LEAST(100, COALESCE((
        SELECT SUM(
            CASE WHEN i.status = 'under_construction' THEN 25
                 WHEN i.status = 'planning' THEN 15
                 WHEN i.status = 'announced' THEN 10
                 ELSE 0 END
        ) FROM layers.infrastructure i
        WHERE ST_DWithin(p.centroid::geography, i.centroid::geography, 2000)
    ), 0)::INTEGER),

    -- Supply change score from the supply pipeline table
    LEAST(100, COALESCE((
        SELECT sp.supply_increase_pct FROM gold.supply_pipeline sp
        WHERE sp.project_name = p.project_name
    ), 0)::INTEGER),

    -- Composite placeholder (computed in next UPDATE)
    0, '', ''

FROM bronze.dda_plots p
WHERE p.land_use_category IN ('RESIDENTIAL', 'MIXED USE')
  AND p.centroid IS NOT NULL
ON CONFLICT (plot_number) DO UPDATE SET
    construction_intensity = EXCLUDED.construction_intensity,
    infrastructure_score = EXCLUDED.infrastructure_score,
    supply_change_score = EXCLUDED.supply_change_score,
    updated_at = now();

-- Compute composite score + label + implication
UPDATE gold.transformation_score SET
    transformation_score = LEAST(100, (
        construction_intensity * 0.30 +
        infrastructure_score * 0.40 +
        supply_change_score * 0.30
    )::INTEGER),

    transformation_label = CASE
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 75
            THEN 'MASSIVE CHANGE'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 55
            THEN 'SIGNIFICANT'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 35
            THEN 'MODERATE'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 15
            THEN 'STABLE'
        ELSE 'STATIC'
    END,

    implication = CASE
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 75
            THEN 'Area will look completely different in 3-5 years. High construction disruption now, but strong appreciation potential.'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 55
            THEN 'Significant development coming. Expect 2-3 years of construction activity. Metro/infrastructure will boost values.'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 35
            THEN 'Some new development planned. Area character mostly preserved but supply increasing.'
        WHEN (construction_intensity * 0.30 + infrastructure_score * 0.40 + supply_change_score * 0.30) >= 15
            THEN 'Mature area with minimal change expected. What you see is what you get.'
        ELSE 'Fully developed. No significant changes planned. Stable neighborhood.'
    END;

-- ============================================================
-- LAYER 10: TRUTH LAYER — DLD ↔ GIS cross-validation
-- Does what DLD says match what GIS shows?
--
-- Run AFTER DLD transactions are loaded.
-- Detects conflicts like:
--   - DLD says "Ready" sales but GIS says VACANT_ZONED
--   - DLD says "Off-plan" but GIS says BUILT
--   - DLD project name doesn't match DDA community
-- ============================================================

CREATE TABLE IF NOT EXISTS gold.truth_validation (
    plot_number             TEXT PRIMARY KEY,

    -- DDA says
    dda_project             TEXT,
    dda_land_use            TEXT,
    dda_max_height          TEXT,
    dda_plot_status         TEXT,

    -- DLD says (aggregated from transactions on this community)
    dld_project_name        TEXT,
    dld_transaction_count   INTEGER,
    dld_last_sale_date      DATE,
    dld_avg_price           NUMERIC,
    dld_reg_type            TEXT,          -- 'Ready' or 'Off-plan' (mode)

    -- Validation results
    name_match              BOOLEAN,       -- does DLD name match DDA community?
    status_match            BOOLEAN,       -- DLD registration type consistent with GIS status?
    conflict_flag           BOOLEAN,       -- any mismatch detected
    conflict_detail         TEXT,

    updated_at              TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Truth validation population
-- Only runs if DLD transactions table has data
-- ============================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'bronze' AND table_name = 'dld_transactions'
    ) AND EXISTS (
        SELECT 1 FROM bronze.dld_transactions LIMIT 1
    ) THEN
        INSERT INTO gold.truth_validation (
            plot_number, dda_project, dda_land_use, dda_max_height, dda_plot_status,
            dld_project_name, dld_transaction_count, dld_last_sale_date, dld_avg_price, dld_reg_type,
            name_match, status_match, conflict_flag, conflict_detail
        )
        SELECT
            p.plot_number,
            p.project_name, p.land_use, p.max_height, p.plot_status,

            dld.project_name_en,
            dld.txn_count,
            dld.last_sale,
            dld.avg_price,
            dld.reg_type,

            -- Name match
            UPPER(TRIM(p.community_name)) = UPPER(TRIM(dld.project_name_en)),

            -- Status match
            NOT (dld.reg_type = 'Ready' AND p.plot_status = 'VACANT_ZONED'),

            -- Conflict flag
            (dld.reg_type = 'Ready' AND p.plot_status = 'VACANT_ZONED')
            OR (dld.reg_type = 'Off-plan' AND p.plot_status = 'BUILT'),

            -- Conflict detail
            CASE
                WHEN dld.reg_type = 'Ready' AND p.plot_status = 'VACANT_ZONED'
                    THEN 'DLD shows completed transactions but GIS says vacant. Plot likely built.'
                WHEN dld.reg_type = 'Off-plan' AND p.plot_status = 'BUILT'
                    THEN 'DLD shows off-plan sales but GIS says built. May be newly completed.'
                ELSE NULL
            END

        FROM bronze.dda_plots p
        LEFT JOIN LATERAL (
            SELECT
                t.project_name_en,
                COUNT(*) AS txn_count,
                MAX(t.instance_date) AS last_sale,
                ROUND(AVG(t.actual_worth)) AS avg_price,
                MODE() WITHIN GROUP (ORDER BY t.reg_type_en) AS reg_type
            FROM bronze.dld_transactions t
            WHERE UPPER(TRIM(t.project_name_en)) = UPPER(TRIM(p.community_name))
              AND t.trans_group_en = 'Sales'
              AND t.actual_worth > 0
            GROUP BY t.project_name_en
        ) dld ON TRUE
        WHERE p.centroid IS NOT NULL
          AND dld.project_name_en IS NOT NULL
        ON CONFLICT (plot_number) DO UPDATE SET
            dld_project_name = EXCLUDED.dld_project_name,
            dld_transaction_count = EXCLUDED.dld_transaction_count,
            dld_last_sale_date = EXCLUDED.dld_last_sale_date,
            dld_avg_price = EXCLUDED.dld_avg_price,
            dld_reg_type = EXCLUDED.dld_reg_type,
            name_match = EXCLUDED.name_match,
            status_match = EXCLUDED.status_match,
            conflict_flag = EXCLUDED.conflict_flag,
            conflict_detail = EXCLUDED.conflict_detail,
            updated_at = now();

        RAISE NOTICE 'Truth validation complete. DLD transactions found.';
    ELSE
        RAISE NOTICE 'Skipping truth validation — DLD transactions not loaded yet.';
    END IF;
END $$;
