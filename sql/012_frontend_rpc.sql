-- ============================================================
-- FRONTEND RPC FUNCTIONS
-- Single-call endpoints for Mapbox frontend / Supabase client
--
-- Functions:
--   get_plot_intelligence(plot_number)  — all 10 layers for one plot
--   get_amenities_geojson(project, category) — amenity map layer
--   get_infrastructure_geojson()        — infrastructure map overlay
--   get_transit_geojson()               — transit map overlay
-- ============================================================

SET search_path TO public, bronze, layers, gold, tiger;

-- ============================================================
-- get_plot_intelligence: All layers for a single plot
-- Called from plot popup / detail panel in Mapbox frontend
-- ============================================================
CREATE OR REPLACE FUNCTION get_plot_intelligence(p_plot_number TEXT)
RETURNS JSON
LANGUAGE SQL
SECURITY DEFINER
AS $$
SELECT json_build_object(
    -- Layer 1: Plot basics (DDA GIS)
    'plot', (SELECT row_to_json(sub) FROM (
        SELECT
            plot_number,
            display_name,
            project_name,
            popular_name,
            popular_developer,
            max_height,
            floor_count,
            land_use,
            land_use_category,
            land_use_subtype,
            plot_status,
            estimated_units,
            site_plan_active,
            site_plan_issue_date,
            site_plan_expiry_date,
            plot_area_sqm,
            max_gfa_sqm
        FROM bronze.dda_plots WHERE plot_number = p_plot_number
    ) sub),

    -- Layer 3: View blocking
    'view', (SELECT row_to_json(sub) FROM (
        SELECT
            view_threat_level,
            is_view_blocker,
            blocks_burj_view_for,
            ROUND(burj_khalifa_distance_m::numeric, 0) AS burj_distance_m,
            nearest_asset_name,
            ROUND(nearest_asset_distance_m::numeric, 0) AS nearest_asset_dist_m,
            view_threat_details
        FROM bronze.dda_plots WHERE plot_number = p_plot_number
    ) sub),

    -- Layer 4: Amenity score
    'amenities', (SELECT row_to_json(a) FROM gold.amenity_scores a
                  WHERE a.plot_number = p_plot_number),

    -- Layer 7: Supply pipeline for this project
    'supply', (SELECT row_to_json(sp) FROM gold.supply_pipeline sp
               WHERE sp.project_name = (
                   SELECT project_name FROM bronze.dda_plots WHERE plot_number = p_plot_number
               )),

    -- Layer 8: Transformation score
    'transformation', (SELECT row_to_json(t) FROM gold.transformation_score t
                       WHERE t.plot_number = p_plot_number),

    -- Layer 5: Nearby infrastructure (within 3km)
    'infrastructure', (SELECT json_agg(sub ORDER BY sub.distance_m) FROM (
        SELECT
            i.name,
            i.infra_type AS type,
            i.status,
            i.expected_completion,
            i.developer_entity,
            ROUND(ST_Distance(
                (SELECT centroid FROM bronze.dda_plots WHERE plot_number = p_plot_number)::geography,
                i.centroid::geography
            )::numeric, 0) AS distance_m,
            i.expected_value_impact_pct AS value_impact_pct,
            i.notes
        FROM layers.infrastructure i
        WHERE ST_DWithin(
            (SELECT centroid FROM bronze.dda_plots WHERE plot_number = p_plot_number)::geography,
            i.centroid::geography, 3000
        )
    ) sub),

    -- Layer 6: Nearby transit (within 3km)
    'transit', (SELECT json_agg(sub ORDER BY sub.distance_m) FROM (
        SELECT
            COALESCE(t.station_name, t.name) AS name,
            t.line_name,
            t.transit_type AS type,
            t.status,
            t.expected_opening,
            ROUND(ST_Distance(
                (SELECT centroid FROM bronze.dda_plots WHERE plot_number = p_plot_number)::geography,
                t.geometry::geography
            )::numeric, 0) AS distance_m,
            t.value_impact_pct
        FROM layers.transit t
        WHERE ST_DWithin(
            (SELECT centroid FROM bronze.dda_plots WHERE plot_number = p_plot_number)::geography,
            t.geometry::geography, 3000
        )
    ) sub),

    -- Layer 10: Truth validation (if DLD loaded)
    'truth', (SELECT row_to_json(tv) FROM gold.truth_validation tv
              WHERE tv.plot_number = p_plot_number),

    -- All popular names for this project
    'popular_names', (SELECT all_popular_names FROM bronze.dda_plots
                      WHERE plot_number = p_plot_number)
);
$$;

-- ============================================================
-- get_amenities_geojson: GeoJSON for amenity map layer toggle
-- Optional filters: project name, amenity category
-- ============================================================
CREATE OR REPLACE FUNCTION get_amenities_geojson(
    p_project TEXT DEFAULT NULL,
    p_category TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE SQL
SECURITY DEFINER
AS $$
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', COALESCE(json_agg(json_build_object(
        'type', 'Feature',
        'properties', json_build_object(
            'name', a.name,
            'type', a.amenity_type,
            'category', a.amenity_category,
            'rating', a.rating,
            'total_ratings', a.total_ratings,
            'source', a.source,
            'is_operational', a.is_operational
        ),
        'geometry', ST_AsGeoJSON(a.geometry)::json
    )), '[]'::json)
)
FROM layers.amenities a
WHERE (p_category IS NULL OR a.amenity_category = p_category)
  AND (p_project IS NULL OR ST_DWithin(
      a.geometry::geography,
      (SELECT ST_Centroid(ST_Collect(geometry))::geography
       FROM bronze.dda_plots
       WHERE project_name ILIKE '%' || p_project || '%'),
      5000
  ));
$$;

-- ============================================================
-- get_infrastructure_geojson: GeoJSON for infrastructure overlay
-- ============================================================
CREATE OR REPLACE FUNCTION get_infrastructure_geojson()
RETURNS JSON
LANGUAGE SQL
SECURITY DEFINER
AS $$
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', COALESCE(json_agg(json_build_object(
        'type', 'Feature',
        'properties', json_build_object(
            'name', i.name,
            'type', i.infra_type,
            'status', i.status,
            'expected_completion', i.expected_completion,
            'investment_aed', i.investment_aed,
            'developer', i.developer_entity,
            'value_impact_pct', i.expected_value_impact_pct,
            'impact_radius_m', i.impact_radius_m,
            'notes', i.notes
        ),
        'geometry', ST_AsGeoJSON(i.geometry)::json
    )), '[]'::json)
)
FROM layers.infrastructure i;
$$;

-- ============================================================
-- get_transit_geojson: GeoJSON for transit map overlay
-- ============================================================
CREATE OR REPLACE FUNCTION get_transit_geojson()
RETURNS JSON
LANGUAGE SQL
SECURITY DEFINER
AS $$
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', COALESCE(json_agg(json_build_object(
        'type', 'Feature',
        'properties', json_build_object(
            'name', COALESCE(t.station_name, t.name),
            'line', t.line_name,
            'type', t.transit_type,
            'status', t.status,
            'expected_opening', t.expected_opening,
            'value_impact_pct', t.value_impact_pct
        ),
        'geometry', ST_AsGeoJSON(t.geometry)::json
    )), '[]'::json)
)
FROM layers.transit t;
$$;

-- ============================================================
-- get_project_dashboard: Summary dashboard data for a project
-- Used by the frontend project overview page
-- ============================================================
CREATE OR REPLACE FUNCTION get_project_dashboard(p_project TEXT)
RETURNS JSON
LANGUAGE SQL
SECURITY DEFINER
AS $$
SELECT json_build_object(
    -- Project overview
    'project_name', p_project,
    'popular_names', (
        SELECT ARRAY_AGG(DISTINCT ppn.popular_name ORDER BY ppn.popular_name)
        FROM bronze.project_popular_names ppn
        WHERE ppn.dda_project_name ILIKE '%' || p_project || '%'
    ),

    -- Plot stats
    'plot_stats', (SELECT row_to_json(sub) FROM (
        SELECT
            COUNT(*) AS total_plots,
            COUNT(*) FILTER (WHERE plot_status = 'BUILT') AS built,
            COUNT(*) FILTER (WHERE plot_status = 'UNDER_CONSTRUCTION') AS under_construction,
            COUNT(*) FILTER (WHERE plot_status = 'APPROVED') AS approved,
            COUNT(*) FILTER (WHERE plot_status = 'VACANT_ZONED') AS vacant,
            SUM(estimated_units) AS total_units,
            ROUND(AVG(floor_count)::numeric, 1) AS avg_floors,
            ROUND(SUM(plot_area_sqm)::numeric, 0) AS total_area_sqm
        FROM bronze.dda_plots
        WHERE project_name ILIKE '%' || p_project || '%'
    ) sub),

    -- Supply pipeline
    'supply', (SELECT row_to_json(sp) FROM gold.supply_pipeline sp
               WHERE sp.project_name ILIKE '%' || p_project || '%' LIMIT 1),

    -- View threat summary
    'view_threats', (SELECT row_to_json(sub) FROM (
        SELECT
            COUNT(*) FILTER (WHERE view_threat_level = 'CRITICAL') AS critical,
            COUNT(*) FILTER (WHERE view_threat_level = 'HIGH') AS high,
            COUNT(*) FILTER (WHERE view_threat_level = 'MEDIUM') AS medium,
            COUNT(*) FILTER (WHERE is_view_blocker) AS blockers,
            ROUND(AVG(burj_khalifa_distance_m)::numeric, 0) AS avg_burj_distance_m
        FROM bronze.dda_plots
        WHERE project_name ILIKE '%' || p_project || '%'
    ) sub),

    -- Avg amenity score
    'avg_amenity', (SELECT row_to_json(sub) FROM (
        SELECT
            ROUND(AVG(amenity_score)::numeric, 0) AS avg_score,
            MODE() WITHIN GROUP (ORDER BY amenity_grade) AS typical_grade,
            COUNT(*) AS scored_plots
        FROM gold.amenity_scores a
        JOIN bronze.dda_plots p ON p.plot_number = a.plot_number
        WHERE p.project_name ILIKE '%' || p_project || '%'
    ) sub),

    -- Avg transformation score
    'avg_transformation', (SELECT row_to_json(sub) FROM (
        SELECT
            ROUND(AVG(transformation_score)::numeric, 0) AS avg_score,
            MODE() WITHIN GROUP (ORDER BY transformation_label) AS typical_label
        FROM gold.transformation_score t
        JOIN bronze.dda_plots p ON p.plot_number = t.plot_number
        WHERE p.project_name ILIKE '%' || p_project || '%'
    ) sub),

    -- Nearby infrastructure count
    'infra_nearby', (SELECT COUNT(DISTINCT i.id)
        FROM layers.infrastructure i
        WHERE ST_DWithin(
            i.centroid::geography,
            (SELECT ST_Centroid(ST_Collect(geometry))::geography
             FROM bronze.dda_plots WHERE project_name ILIKE '%' || p_project || '%'),
            3000
        )
    )
);
$$;
