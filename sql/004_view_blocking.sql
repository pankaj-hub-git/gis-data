-- ============================================================
-- View Blocking Analysis
--
-- DEFINITIONS:
--   View Corridor  = The straight-line path from a plot's centroid
--                     to a visual asset (e.g. Burj Khalifa).
--   View Blocker   = A DIFFERENT plot that:
--                     (a) intersects the view corridor, AND
--                     (b) is CLOSER to the viewer than the asset, AND
--                     (c) has sufficient height (floor_count) to
--                         obstruct the sightline at that distance.
--   View Threat    = A flag on the viewer's plot saying:
--                     "There is at least one existing or potential
--                      blocker between you and this asset."
--
-- HEIGHT MODEL (simplified 2D elevation angle):
--   At distance D (meters) from a viewer, a building of height H
--   blocks the view if:
--     H / D  >  asset_height / asset_distance
--   i.e. the blocker's angular height exceeds the asset's.
--
--   For Burj Khalifa (828m):
--     At 1km away,  a 50m building at 500m blocks it (50/500 = 0.10 > 828/1000 = 0.83) — NO
--     At 1km away,  a 200m building at 300m blocks it (200/300 = 0.67 < 0.83) — NO
--     At 2km away,  a 100m building at 500m blocks it (100/500 = 0.20 < 828/2000 = 0.41) — NO
--     At 2km away,  a 300m building at 500m blocks it (300/500 = 0.60 > 0.41) — YES
--   So proximity + height together determine blocking.
--
-- For practical threat flagging we use a simpler heuristic:
--   A plot is a VIEW BLOCKING THREAT for an asset if:
--     1. It is within the asset's buffer_radius (premium view zone)
--     2. It is buildable (is_buildable = TRUE)
--     3. Its permitted height (floor_count) can obstruct views
--        from plots BEHIND it (further from the asset)
--
-- ============================================================

-- Add view-related columns to plots
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS burj_khalifa_distance_m   DOUBLE PRECISION;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS burj_khalifa_bearing_deg  DOUBLE PRECISION;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS nearest_asset_name        TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS nearest_asset_distance_m  DOUBLE PRECISION;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS view_threat_level         TEXT;  -- NONE | LOW | MEDIUM | HIGH | CRITICAL
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS view_threat_details       JSONB;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS is_view_blocker           BOOLEAN;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS blocks_burj_view_for      INTEGER DEFAULT 0;  -- count of plots it blocks

-- ============================================================
-- 1. Compute distance and bearing from each plot to Burj Khalifa
-- ============================================================
UPDATE bronze.dda_plots p
SET
    burj_khalifa_distance_m = ST_Distance(
        p.centroid::geography,
        a.geometry::geography
    ),
    burj_khalifa_bearing_deg = degrees(
        ST_Azimuth(p.centroid, a.geometry)
    )
FROM bronze.visual_assets a
WHERE a.asset_name = 'Burj Khalifa'
  AND p.centroid IS NOT NULL;

-- ============================================================
-- 2. Compute nearest visual asset for each plot
-- ============================================================
UPDATE bronze.dda_plots p
SET
    nearest_asset_name = sub.asset_name,
    nearest_asset_distance_m = sub.dist_m
FROM (
    SELECT DISTINCT ON (p2.id)
        p2.id AS plot_id,
        a.asset_name,
        ST_Distance(p2.centroid::geography, a.geometry::geography) AS dist_m
    FROM bronze.dda_plots p2
    CROSS JOIN bronze.visual_assets a
    WHERE p2.centroid IS NOT NULL
    ORDER BY p2.id, ST_Distance(p2.centroid::geography, a.geometry::geography)
) sub
WHERE p.id = sub.plot_id;

-- ============================================================
-- 3. View threat level classification
--
-- Based on distance to Burj Khalifa + buildable height context:
--   CRITICAL : within 500m, buildable, floor_count >= 20
--              — almost certainly blocks Burj view for someone
--   HIGH     : within 1km, buildable, floor_count >= 15
--              — high probability of view blocking
--   MEDIUM   : within 2km, buildable, floor_count >= 10
--              — moderate risk depending on exact position
--   LOW      : within 3km, buildable, floor_count >= 5
--              — limited blocking potential
--   NONE     : non-buildable, or too far, or too short
-- ============================================================
UPDATE bronze.dda_plots
SET view_threat_level = CASE
    -- Non-buildable plots never block views
    WHEN is_buildable IS NOT TRUE THEN 'NONE'

    -- CRITICAL: very close + very tall
    WHEN burj_khalifa_distance_m <= 500 AND COALESCE(floor_count, 0) >= 20 THEN 'CRITICAL'

    -- HIGH: close + tall
    WHEN burj_khalifa_distance_m <= 1000 AND COALESCE(floor_count, 0) >= 15 THEN 'HIGH'

    -- MEDIUM: moderate distance + moderate height
    WHEN burj_khalifa_distance_m <= 2000 AND COALESCE(floor_count, 0) >= 10 THEN 'MEDIUM'

    -- LOW: further out but still has height
    WHEN burj_khalifa_distance_m <= 3000 AND COALESCE(floor_count, 0) >= 5 THEN 'LOW'

    -- Also flag plots that don't have height data yet but are close + buildable
    WHEN burj_khalifa_distance_m <= 1000 AND floor_count IS NULL AND is_buildable THEN 'MEDIUM'
    WHEN burj_khalifa_distance_m <= 500 AND floor_count IS NULL AND is_buildable THEN 'HIGH'

    ELSE 'NONE'
END
WHERE burj_khalifa_distance_m IS NOT NULL;

-- ============================================================
-- 4. Identify actual view blockers using spatial corridor check
--
-- A plot is a "view blocker" if:
--   a) It is buildable with meaningful height
--   b) It sits IN BETWEEN other plots and the Burj Khalifa
--      (bearing alignment within ±15 degrees)
--   c) It is closer to the Burj than the plots behind it
--
-- We flag is_view_blocker = TRUE and count how many plots
-- behind it would be affected.
-- ============================================================

-- Step 4a: Mark plots as view blockers
-- A plot blocks Burj views if it's within 3km, buildable, and has height
UPDATE bronze.dda_plots
SET is_view_blocker = (
    is_buildable IS TRUE
    AND COALESCE(floor_count, 0) >= 5
    AND burj_khalifa_distance_m <= 3000
    AND burj_khalifa_distance_m IS NOT NULL
);

-- Step 4b: Count how many plots each blocker affects
-- A blocker affects a "victim" plot if:
--   - victim is FURTHER from the Burj than the blocker
--   - victim has a SIMILAR bearing to the Burj (±10 degrees)
--   - both are within 5km of the Burj
WITH blocker_impact AS (
    SELECT
        blocker.id AS blocker_id,
        COUNT(victim.id) AS victims
    FROM bronze.dda_plots blocker
    JOIN bronze.dda_plots victim
      ON victim.id != blocker.id
      AND victim.burj_khalifa_distance_m > blocker.burj_khalifa_distance_m
      AND ABS(victim.burj_khalifa_bearing_deg - blocker.burj_khalifa_bearing_deg) < 10
      AND victim.burj_khalifa_distance_m <= 5000
    WHERE blocker.is_view_blocker = TRUE
    GROUP BY blocker.id
)
UPDATE bronze.dda_plots p
SET blocks_burj_view_for = bi.victims
FROM blocker_impact bi
WHERE p.id = bi.blocker_id;

-- ============================================================
-- 5. Build view threat detail JSON for each affected plot
--
-- For plots that have blockers between them and the Burj,
-- record what's blocking them.
-- ============================================================
UPDATE bronze.dda_plots victim
SET view_threat_details = sub.details
FROM (
    SELECT
        v.id AS victim_id,
        jsonb_build_object(
            'asset', 'Burj Khalifa',
            'victim_distance_m', ROUND(v.burj_khalifa_distance_m::numeric, 0),
            'victim_bearing_deg', ROUND(v.burj_khalifa_bearing_deg::numeric, 1),
            'blockers', jsonb_agg(
                jsonb_build_object(
                    'plot_id', b.id,
                    'plot_number', b.plot_number,
                    'project_name', b.project_name,
                    'floor_count', b.floor_count,
                    'max_height', b.max_height,
                    'distance_to_burj_m', ROUND(b.burj_khalifa_distance_m::numeric, 0),
                    'distance_to_victim_m', ROUND(ST_Distance(v.centroid::geography, b.centroid::geography)::numeric, 0)
                ) ORDER BY b.burj_khalifa_distance_m
            ),
            'blocker_count', COUNT(b.id),
            'threat_summary', CONCAT(
                'This plot at ',
                ROUND(v.burj_khalifa_distance_m::numeric, 0),
                'm from Burj Khalifa has ',
                COUNT(b.id),
                ' potential view blocker(s) between it and the Burj. ',
                'Projects involved: ',
                string_agg(DISTINCT b.project_name, ', ')
            )
        ) AS details
    FROM bronze.dda_plots v
    JOIN bronze.dda_plots b
      ON b.id != v.id
      AND b.is_view_blocker = TRUE
      AND b.burj_khalifa_distance_m < v.burj_khalifa_distance_m
      AND ABS(v.burj_khalifa_bearing_deg - b.burj_khalifa_bearing_deg) < 10
    WHERE v.burj_khalifa_distance_m <= 5000
      AND v.centroid IS NOT NULL
    GROUP BY v.id, v.burj_khalifa_distance_m, v.burj_khalifa_bearing_deg
) sub
WHERE victim.id = sub.victim_id;

-- ============================================================
-- 6. View: Project-level Burj view blocking threat summary
--
-- "This project has a chance of Burj view blocking"
-- ============================================================
CREATE OR REPLACE VIEW bronze.project_view_threat AS
SELECT
    p.project_name,
    COUNT(*)                                                   AS total_plots,
    COUNT(*) FILTER (WHERE p.is_view_blocker)                  AS plots_that_block_views,
    COALESCE(SUM(p.blocks_burj_view_for), 0)                  AS total_plots_affected,
    COUNT(*) FILTER (WHERE p.view_threat_level = 'CRITICAL')   AS critical_threats,
    COUNT(*) FILTER (WHERE p.view_threat_level = 'HIGH')       AS high_threats,
    COUNT(*) FILTER (WHERE p.view_threat_level = 'MEDIUM')     AS medium_threats,
    COUNT(*) FILTER (WHERE p.view_threat_level = 'LOW')        AS low_threats,
    ROUND(AVG(p.burj_khalifa_distance_m)::numeric, 0)         AS avg_distance_to_burj_m,
    ROUND(MIN(p.burj_khalifa_distance_m)::numeric, 0)         AS closest_plot_to_burj_m,
    COUNT(*) FILTER (WHERE p.view_threat_details IS NOT NULL)  AS plots_with_blockers_ahead,
    CASE
        WHEN COUNT(*) FILTER (WHERE p.view_threat_level = 'CRITICAL') > 0
            THEN 'CRITICAL: This project has plots that critically block Burj Khalifa views'
        WHEN COUNT(*) FILTER (WHERE p.view_threat_level = 'HIGH') > 0
            THEN 'HIGH: This project has a high chance of Burj Khalifa view blocking'
        WHEN COUNT(*) FILTER (WHERE p.view_threat_level = 'MEDIUM') > 0
            THEN 'MEDIUM: This project has a moderate chance of Burj Khalifa view blocking'
        WHEN COUNT(*) FILTER (WHERE p.view_threat_level = 'LOW') > 0
            THEN 'LOW: This project has some plots that may partially block Burj Khalifa views'
        ELSE 'NONE: No significant Burj Khalifa view blocking risk'
    END AS project_threat_statement
FROM bronze.dda_plots p
WHERE p.project_name IS NOT NULL
GROUP BY p.project_name
HAVING COUNT(*) FILTER (WHERE p.view_threat_level != 'NONE') > 0
   OR COUNT(*) FILTER (WHERE p.is_view_blocker) > 0
ORDER BY
    COUNT(*) FILTER (WHERE p.view_threat_level = 'CRITICAL') DESC,
    COUNT(*) FILTER (WHERE p.view_threat_level = 'HIGH') DESC,
    AVG(p.burj_khalifa_distance_m);

-- ============================================================
-- 7. View: Per-plot Burj view blocking detail
--    For frontend / Mapbox popup display
-- ============================================================
CREATE OR REPLACE VIEW bronze.plot_view_detail AS
SELECT
    p.id,
    p.plot_number,
    p.project_name,
    p.land_use,
    p.floor_count,
    p.max_height,
    p.is_buildable,
    ROUND(p.burj_khalifa_distance_m::numeric, 0)  AS burj_distance_m,
    ROUND(p.burj_khalifa_bearing_deg::numeric, 1)  AS burj_bearing_deg,
    p.nearest_asset_name,
    ROUND(p.nearest_asset_distance_m::numeric, 0)  AS nearest_asset_distance_m,
    p.view_threat_level,
    p.is_view_blocker,
    p.blocks_burj_view_for,
    p.view_threat_details,
    CASE
        WHEN p.is_view_blocker AND p.blocks_burj_view_for > 0
            THEN CONCAT('WARNING: This plot blocks Burj Khalifa views for ~', p.blocks_burj_view_for, ' nearby plots')
        WHEN p.view_threat_level IN ('CRITICAL', 'HIGH')
            THEN CONCAT('ALERT: ', p.view_threat_level, ' risk — potential Burj view obstruction from nearby development')
        WHEN p.view_threat_level = 'MEDIUM'
            THEN 'NOTICE: Moderate Burj view blocking risk from surrounding plots'
        WHEN p.view_threat_details IS NOT NULL
            THEN CONCAT('INFO: ', (p.view_threat_details->>'blocker_count')::text, ' plot(s) between this plot and Burj Khalifa')
        ELSE NULL
    END AS view_warning_message,
    p.centroid,
    p.geometry
FROM bronze.dda_plots p
WHERE p.burj_khalifa_distance_m IS NOT NULL;
