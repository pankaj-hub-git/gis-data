-- DDA GIS Pipeline: Enrichment queries
-- Run after initial data ingestion to add derived columns

-- ============================================================
-- Add enrichment columns if they don't exist
-- ============================================================
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS floor_count INTEGER;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS land_use_category TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS land_use_subtype TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS centroid GEOMETRY(Point, 4326);
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS estimated_units INTEGER;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS site_plan_active BOOLEAN;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS is_buildable BOOLEAN;

-- ============================================================
-- 1. Parse height strings into floor counts
--    Examples: "G+P+18" → 20, "G+1" → 2, "G+40" → 41, "B+G+M" → 3
--    Logic: count each component as one floor
-- ============================================================
UPDATE bronze.dda_plots
SET floor_count = (
    CASE
        -- Count the number of '+'-separated components
        -- Each component = 1 floor, numeric ones = that many floors
        WHEN max_height IS NOT NULL AND max_height != '' THEN
            (
                SELECT COALESCE(SUM(
                    CASE
                        -- Pure number like "18" → that many floors
                        WHEN part ~ '^\d+$' THEN part::INTEGER
                        -- Letter codes (G, P, M, B, LG, UG, R) → 1 floor each
                        ELSE 1
                    END
                ), 0)
                FROM unnest(string_to_array(UPPER(TRIM(max_height)), '+')) AS part
            )
        ELSE NULL
    END
)
WHERE max_height IS NOT NULL;

-- ============================================================
-- 2. Parse land use into category + subtype
--    "RESIDENTIAL: APARTMENT" → category=RESIDENTIAL, subtype=APARTMENT
--    "COMMERCIAL" → category=COMMERCIAL, subtype=NULL
-- ============================================================
UPDATE bronze.dda_plots
SET
    land_use_category = TRIM(SPLIT_PART(UPPER(land_use), ':', 1)),
    land_use_subtype = NULLIF(TRIM(SPLIT_PART(UPPER(land_use), ':', 2)), '')
WHERE land_use IS NOT NULL;

-- ============================================================
-- 3. Compute centroids
-- ============================================================
UPDATE bronze.dda_plots
SET centroid = ST_Centroid(geometry)
WHERE geometry IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_plots_centroid ON bronze.dda_plots USING GIST (centroid);

-- ============================================================
-- 4. Estimate unit capacity
--    Apartments: GFA / 100 sqm (avg apartment size)
--    Villas: 1 per plot
--    Commercial/Office: GFA / 80 sqm
--    Hotel: GFA / 40 sqm (room size)
--    Mixed: GFA / 100 sqm (approximate)
-- ============================================================
UPDATE bronze.dda_plots
SET estimated_units = (
    CASE
        WHEN land_use_subtype IN ('VILLA', 'TOWNHOUSE') THEN 1
        WHEN land_use_category = 'RESIDENTIAL' THEN
            GREATEST(1, FLOOR(COALESCE(max_gfa_sqm, 0) / 100))::INTEGER
        WHEN land_use_category = 'HOTEL' THEN
            GREATEST(1, FLOOR(COALESCE(max_gfa_sqm, 0) / 40))::INTEGER
        WHEN land_use_category IN ('COMMERCIAL', 'OFFICE') THEN
            GREATEST(1, FLOOR(COALESCE(max_gfa_sqm, 0) / 80))::INTEGER
        WHEN land_use_category = 'MIXED USE' THEN
            GREATEST(1, FLOOR(COALESCE(max_gfa_sqm, 0) / 100))::INTEGER
        WHEN max_gfa_sqm IS NOT NULL AND max_gfa_sqm > 0 THEN
            GREATEST(1, FLOOR(max_gfa_sqm / 100))::INTEGER
        ELSE NULL
    END
)
WHERE land_use IS NOT NULL OR max_gfa_sqm IS NOT NULL;

-- ============================================================
-- 5. Flag active site plans (expiry > today)
-- ============================================================
UPDATE bronze.dda_plots
SET site_plan_active = (
    CASE
        WHEN site_plan_expiry_date IS NOT NULL
         AND site_plan_expiry_date > NOW()
        THEN TRUE
        ELSE FALSE
    END
);

-- ============================================================
-- 6. Flag buildable vs non-buildable plots
--    Non-buildable: landscape, utility, roads, parking, open space, etc.
-- ============================================================
UPDATE bronze.dda_plots
SET is_buildable = (
    CASE
        WHEN land_use_category IN (
            'LANDSCAPE', 'UTILITY', 'ROAD', 'ROADS',
            'INFRASTRUCTURE', 'OPEN SPACE', 'PARKING',
            'WATER BODY', 'CANAL', 'SETBACK', 'BUFFER'
        ) THEN FALSE
        WHEN land_use_subtype IN (
            'LANDSCAPE', 'UTILITY', 'ROAD', 'PARKING',
            'OPEN SPACE', 'GARDEN', 'PARK'
        ) THEN FALSE
        WHEN land_use IS NULL THEN NULL
        ELSE TRUE
    END
);

-- ============================================================
-- Summary view for quick stats
-- ============================================================
CREATE OR REPLACE VIEW bronze.plot_summary AS
SELECT
    project_name,
    land_use_category,
    land_use_subtype,
    COUNT(*) AS plot_count,
    SUM(plot_area_sqm) AS total_area_sqm,
    SUM(max_gfa_sqm) AS total_gfa_sqm,
    SUM(estimated_units) AS total_estimated_units,
    SUM(CASE WHEN site_plan_active THEN 1 ELSE 0 END) AS active_site_plans,
    SUM(CASE WHEN is_buildable THEN 1 ELSE 0 END) AS buildable_plots,
    AVG(floor_count) AS avg_floors
FROM bronze.dda_plots
GROUP BY project_name, land_use_category, land_use_subtype
ORDER BY project_name, land_use_category;

-- ============================================================
-- Per-project ingestion audit view
-- Shows completeness & data quality at a glance
-- ============================================================
CREATE OR REPLACE VIEW bronze.ingestion_audit AS
SELECT
    project_name,
    COUNT(*)                                                         AS total_plots,
    COUNT(*) FILTER (WHERE geometry IS NOT NULL)                     AS with_geometry,
    COUNT(*) FILTER (WHERE geometry IS NULL)                         AS missing_geometry,
    COUNT(*) FILTER (WHERE plot_number IS NOT NULL)                  AS with_plot_number,
    COUNT(*) FILTER (WHERE land_use IS NOT NULL)                     AS with_land_use,
    COUNT(*) FILTER (WHERE max_height IS NOT NULL)                   AS with_height,
    COUNT(*) FILTER (WHERE plot_area_sqm IS NOT NULL AND plot_area_sqm > 0) AS with_area,
    COUNT(*) FILTER (WHERE max_gfa_sqm IS NOT NULL AND max_gfa_sqm > 0)    AS with_gfa,
    COUNT(*) FILTER (WHERE is_buildable)                             AS buildable,
    COUNT(*) FILTER (WHERE site_plan_active)                         AS active_plans,
    MIN(ingested_at)                                                 AS first_ingested,
    MAX(updated_at)                                                  AS last_updated
FROM bronze.dda_plots
GROUP BY project_name
ORDER BY total_plots DESC;
