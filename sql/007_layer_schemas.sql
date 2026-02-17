-- ============================================================
-- ZEROAGENT: Layer schemas + missing base columns
--
-- Creates the `layers` and `gold` schemas for the 10-layer
-- data architecture, and adds columns to dda_plots that the
-- downstream layers depend on.
-- ============================================================

SET search_path TO public, bronze, tiger;

CREATE SCHEMA IF NOT EXISTS layers;
CREATE SCHEMA IF NOT EXISTS gold;

-- ============================================================
-- Add missing columns to dda_plots needed by downstream layers
-- ============================================================

-- plot_status: derived from construction data + site plan dates
-- Values: VACANT_ZONED | APPROVED | UNDER_CONSTRUCTION | BUILT | UNKNOWN
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS plot_status TEXT;

-- display_name: user-facing name (popular_name if available, else project_name)
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS display_name TEXT;

-- ============================================================
-- Derive plot_status from existing data
--
-- Logic:
--   1. If construction_status is known, use it
--   2. If site_plan is expired or absent + no GFA → VACANT_ZONED
--   3. If site_plan active + buildable → APPROVED
--   4. Default → UNKNOWN
-- ============================================================
UPDATE bronze.dda_plots p
SET plot_status = CASE
    -- Check construction status table first
    WHEN EXISTS (
        SELECT 1 FROM bronze.dda_construction_status cs
        WHERE cs.plot_number = p.plot_number
          AND cs.project_name = p.project_name
          AND cs.construction_status ILIKE '%complete%'
    ) THEN 'BUILT'

    WHEN EXISTS (
        SELECT 1 FROM bronze.dda_construction_status cs
        WHERE cs.plot_number = p.plot_number
          AND cs.project_name = p.project_name
          AND cs.construction_status ILIKE '%construct%'
    ) THEN 'UNDER_CONSTRUCTION'

    -- Site plan logic
    WHEN p.site_plan_active = TRUE AND p.is_buildable = TRUE
        THEN 'APPROVED'

    WHEN p.is_buildable = FALSE
        THEN 'BUILT'  -- non-buildable plots (parks, roads) are effectively "built"

    WHEN p.site_plan_expiry_date IS NOT NULL
         AND p.site_plan_expiry_date < NOW()
         AND p.floor_count IS NULL
        THEN 'VACANT_ZONED'

    WHEN p.max_gfa_sqm IS NOT NULL AND p.max_gfa_sqm > 0
        THEN 'APPROVED'

    ELSE 'UNKNOWN'
END;

-- ============================================================
-- Derive display_name (popular_name takes priority)
-- ============================================================
UPDATE bronze.dda_plots
SET display_name = COALESCE(popular_name, INITCAP(project_name), 'Plot ' || plot_number);

CREATE INDEX IF NOT EXISTS idx_plots_status ON bronze.dda_plots (plot_status);
CREATE INDEX IF NOT EXISTS idx_plots_display ON bronze.dda_plots (display_name);
