-- ============================================================
-- Name Resolution Enrichment
--
-- Adds popular_name and related DLD Pulse fields to dda_plots
-- using multi-strategy matching against project_popular_names.
--
-- Matching strategies (in priority order):
--   1. EXACT  — plot_numbers array contains this plot's number
--   2. CONTAINS — DDA project_name contains the mapping's dda_project_name
--   3. FUZZY  — trigram similarity score > 0.3
--
-- When multiple popular names match a single plot, we pick the
-- best one by confidence score, then by match specificity.
-- ============================================================

-- Add name resolution columns to plots
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS popular_name       TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS popular_developer  TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS popular_community  TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS dld_project_id     TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS name_match_method  TEXT;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS name_match_score   DOUBLE PRECISION;
ALTER TABLE bronze.dda_plots ADD COLUMN IF NOT EXISTS all_popular_names  TEXT[];

-- ============================================================
-- Strategy 1: Plot-level exact match (plot_numbers array)
-- Highest confidence — a popular name explicitly lists this plot
-- ============================================================
UPDATE bronze.dda_plots p
SET
    popular_name       = sub.popular_name,
    popular_developer  = sub.developer,
    popular_community  = sub.community,
    dld_project_id     = sub.dld_project_id,
    name_match_method  = 'EXACT_PLOT',
    name_match_score   = 1.0
FROM (
    SELECT DISTINCT ON (pl.id)
        pl.id AS plot_id,
        ppn.popular_name,
        ppn.developer,
        ppn.community,
        ppn.dld_project_id
    FROM bronze.dda_plots pl
    JOIN bronze.project_popular_names ppn
        ON pl.plot_number = ANY(ppn.plot_numbers)
        AND UPPER(pl.project_name) LIKE '%' || UPPER(ppn.dda_project_name) || '%'
    ORDER BY pl.id, ppn.confidence DESC
) sub
WHERE p.id = sub.plot_id;

-- ============================================================
-- Strategy 2: Project-level contains match
-- For plots not yet matched, match by DDA project name
-- If multiple popular names exist for one project, pick best fit
-- ============================================================

-- First, collect ALL popular names per plot into the array
UPDATE bronze.dda_plots p
SET all_popular_names = sub.names
FROM (
    SELECT
        pl.id AS plot_id,
        ARRAY_AGG(DISTINCT ppn.popular_name ORDER BY ppn.popular_name) AS names
    FROM bronze.dda_plots pl
    JOIN bronze.project_popular_names ppn
        ON UPPER(pl.project_name) LIKE '%' || UPPER(ppn.dda_project_name) || '%'
    GROUP BY pl.id
) sub
WHERE p.id = sub.plot_id;

-- For plots without an exact plot-level match, assign best project-level match
-- Prefer: completed projects, then by confidence, then alphabetically
UPDATE bronze.dda_plots p
SET
    popular_name       = sub.popular_name,
    popular_developer  = sub.developer,
    popular_community  = sub.community,
    dld_project_id     = sub.dld_project_id,
    name_match_method  = 'PROJECT_MATCH',
    name_match_score   = 0.7
FROM (
    SELECT DISTINCT ON (pl.id)
        pl.id AS plot_id,
        ppn.popular_name,
        ppn.developer,
        ppn.community,
        ppn.dld_project_id
    FROM bronze.dda_plots pl
    JOIN bronze.project_popular_names ppn
        ON UPPER(pl.project_name) LIKE '%' || UPPER(ppn.dda_project_name) || '%'
    ORDER BY pl.id,
        ppn.confidence DESC,
        CASE ppn.status
            WHEN 'COMPLETED' THEN 1
            WHEN 'UNDER_CONSTRUCTION' THEN 2
            WHEN 'OFF_PLAN' THEN 3
            ELSE 4
        END,
        ppn.popular_name
) sub
WHERE p.id = sub.plot_id
  AND p.popular_name IS NULL;  -- Don't overwrite exact matches

-- ============================================================
-- Strategy 3: Fuzzy match using trigram similarity
-- For plots STILL unmatched, try fuzzy matching on project_name
-- Requires pg_trgm extension (created in 005_popular_names.sql)
-- ============================================================
UPDATE bronze.dda_plots p
SET
    popular_name       = sub.popular_name,
    popular_developer  = sub.developer,
    popular_community  = sub.community,
    dld_project_id     = sub.dld_project_id,
    name_match_method  = 'FUZZY',
    name_match_score   = sub.sim
FROM (
    SELECT DISTINCT ON (pl.id)
        pl.id AS plot_id,
        ppn.popular_name,
        ppn.developer,
        ppn.community,
        ppn.dld_project_id,
        similarity(UPPER(pl.project_name), UPPER(ppn.dda_project_name)) AS sim
    FROM bronze.dda_plots pl
    CROSS JOIN bronze.project_popular_names ppn
    WHERE similarity(UPPER(pl.project_name), UPPER(ppn.dda_project_name)) > 0.3
    ORDER BY pl.id, similarity(UPPER(pl.project_name), UPPER(ppn.dda_project_name)) DESC
) sub
WHERE p.id = sub.plot_id
  AND p.popular_name IS NULL;  -- Don't overwrite better matches

-- ============================================================
-- View: Plot detail with popular names
-- Combines official + popular names for frontend display
-- ============================================================
CREATE OR REPLACE VIEW bronze.plot_names AS
SELECT
    p.id,
    p.objectid,
    p.plot_number,
    p.project_name          AS official_name,
    p.popular_name          AS popular_name,
    p.popular_developer     AS developer,
    p.popular_community     AS sub_community,
    p.community_name        AS dda_community,
    p.all_popular_names,
    p.name_match_method,
    p.name_match_score,
    p.dld_project_id,
    p.land_use,
    p.land_use_category,
    p.floor_count,
    -- Display name: prefer popular, fall back to official
    COALESCE(p.popular_name, p.project_name) AS display_name,
    -- Search text: combine all names for full-text search
    LOWER(
        COALESCE(p.project_name, '') || ' ' ||
        COALESCE(p.popular_name, '') || ' ' ||
        COALESCE(p.popular_developer, '') || ' ' ||
        COALESCE(p.community_name, '') || ' ' ||
        COALESCE(p.popular_community, '') || ' ' ||
        COALESCE(ARRAY_TO_STRING(p.all_popular_names, ' '), '')
    ) AS search_text
FROM bronze.dda_plots p;

-- ============================================================
-- View: Name resolution quality report
-- Shows how well popular names are resolved per project
-- ============================================================
CREATE OR REPLACE VIEW bronze.name_resolution_quality AS
SELECT
    project_name,
    COUNT(*)                                                        AS total_plots,
    COUNT(*) FILTER (WHERE popular_name IS NOT NULL)                AS resolved,
    COUNT(*) FILTER (WHERE popular_name IS NULL)                    AS unresolved,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE popular_name IS NOT NULL) / NULLIF(COUNT(*), 0),
        1
    )                                                               AS resolution_pct,
    COUNT(*) FILTER (WHERE name_match_method = 'EXACT_PLOT')        AS exact_matches,
    COUNT(*) FILTER (WHERE name_match_method = 'PROJECT_MATCH')     AS project_matches,
    COUNT(*) FILTER (WHERE name_match_method = 'FUZZY')             AS fuzzy_matches,
    ROUND(AVG(name_match_score)::numeric, 2)                        AS avg_confidence,
    COUNT(DISTINCT popular_name)                                    AS distinct_popular_names,
    ARRAY_AGG(DISTINCT popular_name ORDER BY popular_name)
        FILTER (WHERE popular_name IS NOT NULL)                     AS popular_names_found
FROM bronze.dda_plots
WHERE project_name IS NOT NULL
GROUP BY project_name
ORDER BY total_plots DESC;

-- ============================================================
-- Function: Search plots by any name (official or popular)
-- Used by frontend search bars, Mapbox popups, etc.
-- ============================================================
CREATE OR REPLACE FUNCTION bronze.search_plots(search_term TEXT, result_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    plot_id         BIGINT,
    plot_number     TEXT,
    official_name   TEXT,
    popular_name    TEXT,
    developer       TEXT,
    display_name    TEXT,
    land_use        TEXT,
    match_rank      DOUBLE PRECISION
) AS $$
    SELECT
        p.id,
        p.plot_number,
        p.project_name,
        p.popular_name,
        p.popular_developer,
        COALESCE(p.popular_name, p.project_name),
        p.land_use,
        GREATEST(
            similarity(UPPER(search_term), UPPER(COALESCE(p.project_name, ''))),
            similarity(UPPER(search_term), UPPER(COALESCE(p.popular_name, ''))),
            similarity(UPPER(search_term), UPPER(COALESCE(p.popular_developer, '')))
        ) AS match_rank
    FROM bronze.dda_plots p
    WHERE
        UPPER(p.project_name) LIKE '%' || UPPER(search_term) || '%'
        OR UPPER(p.popular_name) LIKE '%' || UPPER(search_term) || '%'
        OR UPPER(p.popular_developer) LIKE '%' || UPPER(search_term) || '%'
        OR UPPER(p.community_name) LIKE '%' || UPPER(search_term) || '%'
        OR search_term ILIKE ANY(p.all_popular_names)
        OR similarity(UPPER(search_term), UPPER(COALESCE(p.project_name, ''))) > 0.3
        OR similarity(UPPER(search_term), UPPER(COALESCE(p.popular_name, ''))) > 0.3
    ORDER BY match_rank DESC
    LIMIT result_limit;
$$ LANGUAGE sql STABLE;
