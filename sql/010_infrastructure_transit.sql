-- ============================================================
-- LAYERS 5+6: INFRASTRUCTURE CATALYSTS + METRO/TRANSIT
--
-- Source: Dubai 2040 Urban Master Plan + RTA open data + manual
-- Purpose: Map planned infrastructure that changes area values
--
-- Infrastructure types:
--   metro_line, metro_station, highway, bridge, park, hospital,
--   school, mall, museum, expo, free_zone, government, waterfront
--
-- Transit types:
--   metro_red, metro_green, metro_blue, tram, bus_route,
--   water_bus, monorail
-- ============================================================

SET search_path TO public, bronze, layers, gold, tiger;

-- ============================================================
-- LAYER 5: INFRASTRUCTURE
-- ============================================================
CREATE TABLE IF NOT EXISTS layers.infrastructure (
    id                      SERIAL PRIMARY KEY,
    name                    TEXT NOT NULL,
    infra_type              TEXT NOT NULL,
    status                  TEXT NOT NULL,     -- announced | planning | under_construction | completed | operational

    -- Timeline
    announced_date          DATE,
    expected_completion     DATE,
    actual_completion       DATE,

    -- Investment
    investment_aed          NUMERIC,
    developer_entity        TEXT,              -- RTA, Dubai Municipality, Emaar, etc.

    -- Impact
    expected_value_impact_pct NUMERIC,         -- expected % impact on nearby property values
    impact_radius_m         INTEGER,           -- how far the impact reaches

    -- Geometry
    geometry                geometry(Geometry, 4326),
    centroid                geometry(Point, 4326),

    -- Dubai 2040 reference
    dubai_2040_zone         TEXT,              -- Urban Center, Urban Suburb, Rural, etc.
    d33_priority            BOOLEAN DEFAULT FALSE,

    source                  TEXT DEFAULT 'manual',
    notes                   TEXT,

    created_at              TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_infra_geom ON layers.infrastructure USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_infra_centroid ON layers.infrastructure USING GIST (centroid);
CREATE INDEX IF NOT EXISTS idx_infra_type ON layers.infrastructure (infra_type);
CREATE INDEX IF NOT EXISTS idx_infra_status ON layers.infrastructure (status);

-- ============================================================
-- LAYER 6: TRANSIT
-- ============================================================
CREATE TABLE IF NOT EXISTS layers.transit (
    id                      SERIAL PRIMARY KEY,
    name                    TEXT NOT NULL,
    transit_type            TEXT NOT NULL,
    line_name               TEXT,
    station_name            TEXT,

    status                  TEXT NOT NULL,     -- operational | under_construction | planned
    expected_opening        DATE,

    geometry                geometry(Geometry, 4326),

    -- Impact
    value_impact_pct        NUMERIC,

    source                  TEXT DEFAULT 'rta',
    created_at              TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_transit_geom ON layers.transit USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_transit_type ON layers.transit (transit_type);

-- ============================================================
-- SEED: Metro stations near target areas
-- Coordinates in WGS84 (approximate — refine with RTA data)
-- ============================================================

-- Red Line stations near Business Bay / Downtown
INSERT INTO layers.transit (name, transit_type, line_name, station_name, status, geometry, value_impact_pct) VALUES
    ('Business Bay Metro', 'metro_red', 'Red Line', 'Business Bay', 'operational',
     ST_SetSRID(ST_MakePoint(55.2617, 25.1882), 4326), 15),
    ('Burj Khalifa/Dubai Mall Metro', 'metro_red', 'Red Line', 'Burj Khalifa/Dubai Mall', 'operational',
     ST_SetSRID(ST_MakePoint(55.2722, 25.2002), 4326), 20),
    ('Financial Centre Metro', 'metro_red', 'Red Line', 'Financial Centre', 'operational',
     ST_SetSRID(ST_MakePoint(55.2750, 25.2100), 4326), 12),
    ('Emirates Towers Metro', 'metro_red', 'Red Line', 'Emirates Towers', 'operational',
     ST_SetSRID(ST_MakePoint(55.2820, 25.2170), 4326), 10),

    -- Blue Line (PLANNED — the big catalyst for Dubai Hills)
    ('Dubai Hills Mall Station', 'metro_blue', 'Blue Line', 'Dubai Hills Mall', 'planned',
     ST_SetSRID(ST_MakePoint(55.2440, 25.0750), 4326), 20),
    ('Dubai Hills Station', 'metro_blue', 'Blue Line', 'Dubai Hills', 'planned',
     ST_SetSRID(ST_MakePoint(55.2350, 25.0650), 4326), 18),
    ('Al Khail Station', 'metro_blue', 'Blue Line', 'Al Khail', 'planned',
     ST_SetSRID(ST_MakePoint(55.2500, 25.0900), 4326), 15),

    -- Tram (Dubai Marina / JBR area — reference comparison)
    ('Dubai Marina Tram', 'tram', 'Dubai Tram', 'Dubai Marina', 'operational',
     ST_SetSRID(ST_MakePoint(55.1390, 25.0780), 4326), 8)
ON CONFLICT DO NOTHING;

-- ============================================================
-- SEED: Key infrastructure projects
-- ============================================================
INSERT INTO layers.infrastructure (
    name, infra_type, status, expected_completion,
    investment_aed, expected_value_impact_pct, impact_radius_m,
    geometry, centroid, developer_entity, notes
) VALUES
    -- Metro Blue Line — biggest catalyst for Dubai Hills
    ('Metro Blue Line Extension', 'metro_line', 'under_construction', '2029-01-01',
     18000000000, 20, 2000,
     ST_SetSRID(ST_GeomFromText(
         'LINESTRING(55.2350 25.0650, 55.2440 25.0750, 55.2500 25.0900, 55.2617 25.1882)'
     ), 4326),
     ST_SetSRID(ST_MakePoint(55.2400, 25.0700), 4326),
     'RTA',
     'Route 2020 extension. 14 stations. AED 18B. Connects Dubai Hills, Academic City, Airport.'),

    -- Dubai Hills Mall Phase 2
    ('Dubai Hills Mall Phase 2', 'mall', 'under_construction', '2027-06-01',
     800000000, 10, 1000,
     ST_SetSRID(ST_MakePoint(55.2460, 25.0780), 4326),
     ST_SetSRID(ST_MakePoint(55.2460, 25.0780), 4326),
     'Emaar Properties',
     '+120,000 sqm retail. Walkability improvement for Dubai Hills Estate.'),

    -- Dubai Hills Central Park Expansion
    ('Dubai Hills Central Park Expansion', 'park', 'under_construction', '2026-12-01',
     350000000, 8, 800,
     ST_SetSRID(ST_MakePoint(55.2380, 25.0680), 4326),
     ST_SetSRID(ST_MakePoint(55.2380, 25.0680), 4326),
     'Emaar Properties',
     '+30 hectares green space. 60% complete per satellite imagery.'),

    -- Business Bay Canal Promenade
    ('Business Bay Canal Promenade', 'waterfront', 'planning', '2028-01-01',
     500000000, 12, 500,
     ST_SetSRID(ST_GeomFromText(
         'LINESTRING(55.2550 25.1850, 55.2650 25.1870, 55.2750 25.1880)'
     ), 4326),
     ST_SetSRID(ST_MakePoint(55.2650, 25.1850), 4326),
     'Dubai Properties',
     'Canal-side pedestrian promenade + retail activation.'),

    -- GEMS Dubai Hills School
    ('GEMS Dubai Hills School', 'school', 'operational', '2025-09-01',
     200000000, 7, 1500,
     ST_SetSRID(ST_MakePoint(55.2500, 25.0850), 4326),
     ST_SetSRID(ST_MakePoint(55.2500, 25.0850), 4326),
     'GEMS Education',
     'Premium tier. 2500 students. Operational since Sept 2025.'),

    -- Business Bay Bridge to Downtown
    ('Business Bay Pedestrian Bridge', 'bridge', 'under_construction', '2027-03-01',
     150000000, 8, 500,
     ST_SetSRID(ST_MakePoint(55.2700, 25.1920), 4326),
     ST_SetSRID(ST_MakePoint(55.2700, 25.1920), 4326),
     'RTA',
     'Pedestrian/cycling bridge connecting Business Bay to Downtown Dubai.'),

    -- Dubai Hills Hospital (Mediclinic)
    ('Mediclinic Dubai Hills Hospital', 'hospital', 'operational', '2024-06-01',
     400000000, 8, 2000,
     ST_SetSRID(ST_MakePoint(55.2420, 25.0820), 4326),
     ST_SetSRID(ST_MakePoint(55.2420, 25.0820), 4326),
     'Mediclinic',
     '200-bed hospital. Major amenity boost for Dubai Hills Estate.')
ON CONFLICT DO NOTHING;

-- ============================================================
-- View: Infrastructure impact on nearby plots
-- Shows which plots benefit from each infrastructure project
-- ============================================================
CREATE OR REPLACE VIEW layers.infra_impact AS
SELECT
    i.name                  AS infra_name,
    i.infra_type,
    i.status                AS infra_status,
    i.expected_completion,
    i.expected_value_impact_pct,
    p.plot_number,
    p.project_name,
    p.display_name,
    ROUND(ST_Distance(p.centroid::geography, i.centroid::geography)::numeric, 0) AS distance_m,
    -- Value impact decays with distance
    ROUND((i.expected_value_impact_pct *
        GREATEST(0, 1.0 - ST_Distance(p.centroid::geography, i.centroid::geography)::numeric
                          / GREATEST(i.impact_radius_m, 1))
    )::numeric, 1) AS estimated_impact_pct
FROM layers.infrastructure i
JOIN bronze.dda_plots p
    ON ST_DWithin(p.centroid::geography, i.centroid::geography, i.impact_radius_m)
WHERE p.centroid IS NOT NULL
  AND i.centroid IS NOT NULL
ORDER BY i.name, distance_m;
