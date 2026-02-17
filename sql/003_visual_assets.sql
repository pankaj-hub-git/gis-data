-- ============================================================
-- Visual assets: landmarks and features that command premium views
-- These are the TARGETS — buildings/plots that might block views
-- TO these assets get flagged as view-blocking threats.
-- ============================================================

CREATE TABLE IF NOT EXISTS bronze.visual_assets (
    id              BIGSERIAL PRIMARY KEY,
    asset_name      TEXT NOT NULL,
    asset_type      TEXT NOT NULL,       -- LANDMARK | WATER_BODY | PARK | MONUMENT
    description     TEXT,
    height_m        DOUBLE PRECISION,    -- Height in meters (for landmarks)
    geometry        GEOMETRY(Geometry, 4326),
    buffer_radius_m INTEGER DEFAULT 500, -- How far the "premium view zone" extends
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_asset_name UNIQUE (asset_name)
);

CREATE INDEX IF NOT EXISTS idx_assets_geom ON bronze.visual_assets USING GIST (geometry);

-- ============================================================
-- Seed data: Dubai visual assets
-- Coordinates in WGS84 (EPSG:4326)
-- ============================================================

-- Burj Khalifa — the #1 view asset in Dubai
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Burj Khalifa',
    'LANDMARK',
    'Tallest building in the world (828m). Primary view asset for Business Bay and Downtown Dubai.',
    828,
    ST_SetSRID(ST_MakePoint(55.2744, 25.1972), 4326),
    2000
) ON CONFLICT (asset_name) DO UPDATE SET
    height_m = EXCLUDED.height_m,
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Dubai Fountain — at the base of Burj Khalifa
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Dubai Fountain',
    'MONUMENT',
    'World''s largest choreographed fountain system at Burj Khalifa Lake.',
    150,  -- water jets reach ~150m
    ST_SetSRID(ST_MakePoint(55.2747, 25.1953), 4326),
    1000
) ON CONFLICT (asset_name) DO UPDATE SET
    height_m = EXCLUDED.height_m,
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Burj Park — island park in Burj Khalifa Lake
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Burj Park',
    'PARK',
    'Island park within the Burj Khalifa Lake, popular viewing spot.',
    NULL,
    ST_SetSRID(ST_MakePoint(55.2750, 25.1938), 4326),
    800
) ON CONFLICT (asset_name) DO UPDATE SET
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Burj Khalifa Lake / Downtown Water Feature
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Burj Khalifa Lake',
    'WATER_BODY',
    'Artificial lake surrounding Burj Park, setting for the Dubai Fountain.',
    NULL,
    ST_SetSRID(ST_MakePoint(55.2745, 25.1945), 4326),
    800
) ON CONFLICT (asset_name) DO UPDATE SET
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Dubai Water Canal — runs through Business Bay
-- Stored as a simplified line through Business Bay
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Dubai Water Canal',
    'WATER_BODY',
    'Man-made canal running through Business Bay connecting Dubai Creek to the Arabian Gulf.',
    NULL,
    ST_SetSRID(ST_GeomFromText(
        'LINESTRING(55.2550 25.1850, 55.2650 25.1870, 55.2750 25.1880, 55.2850 25.1900, 55.2950 25.1920)'
    ), 4326),
    500
) ON CONFLICT (asset_name) DO UPDATE SET
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Dubai Creek Tower (planned landmark near Business Bay)
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Dubai Creek Tower',
    'LANDMARK',
    'Under-construction observation tower at Dubai Creek Harbour. Will surpass Burj Khalifa.',
    928,
    ST_SetSRID(ST_MakePoint(55.3435, 25.2050), 4326),
    1500
) ON CONFLICT (asset_name) DO UPDATE SET
    height_m = EXCLUDED.height_m,
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Dubai Hills Park (central green space in Dubai Hills Estate)
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Dubai Hills Park',
    'PARK',
    'Large central park within Dubai Hills Estate with Burj Khalifa skyline views.',
    NULL,
    ST_SetSRID(ST_MakePoint(55.2425, 25.1250), 4326),
    600
) ON CONFLICT (asset_name) DO UPDATE SET
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;

-- Dubai Hills Golf Course
INSERT INTO bronze.visual_assets (asset_name, asset_type, description, height_m, geometry, buffer_radius_m)
VALUES (
    'Dubai Hills Golf Course',
    'PARK',
    '18-hole championship golf course with panoramic views of Downtown skyline.',
    NULL,
    ST_SetSRID(ST_MakePoint(55.2380, 25.1300), 4326),
    600
) ON CONFLICT (asset_name) DO UPDATE SET
    geometry = EXCLUDED.geometry,
    buffer_radius_m = EXCLUDED.buffer_radius_m;
