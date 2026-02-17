-- ============================================================
-- LAYER 4: AMENITIES + AMENITY SCORING
-- Source: DDA GIS (auto-populate) + Google Places + OSM
--
-- AMENITY CATEGORIES:
--   education:   school, nursery, university, training_center
--   health:      hospital, clinic, pharmacy, dental, veterinary
--   retail:      mall, supermarket, convenience, market
--   food:        restaurant, cafe, bakery, fast_food
--   recreation:  gym, pool, park, playground, sports_club, cinema, spa
--   worship:     mosque, church, temple
--   transport:   metro_station, bus_stop, taxi_stand, parking
--   services:    bank, atm, post_office, police, fire_station
--   childcare:   daycare, kids_play_area
-- ============================================================

SET search_path TO public, bronze, layers, gold, tiger;

CREATE TABLE IF NOT EXISTS layers.amenities (
    id                  SERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    amenity_type        TEXT NOT NULL,
    amenity_category    TEXT,

    -- Location
    geometry            geometry(Point, 4326),
    address             TEXT,

    -- Quality signals
    rating              NUMERIC,             -- Google rating (1-5)
    total_ratings       INTEGER,             -- number of Google reviews
    price_level         INTEGER,             -- Google price level (1-4)

    -- Metadata
    google_place_id     TEXT UNIQUE,
    osm_id              TEXT,
    source              TEXT DEFAULT 'manual', -- 'google', 'osm', 'dda', 'manual'

    -- Operational
    is_operational      BOOLEAN DEFAULT TRUE,
    opened_date         DATE,
    scraped_at          TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_amenities_geom ON layers.amenities USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_amenities_type ON layers.amenities (amenity_type);
CREATE INDEX IF NOT EXISTS idx_amenities_cat ON layers.amenities (amenity_category);

-- ============================================================
-- Auto-populate amenities from DDA GIS plots
-- Uses land_use field to identify amenity plots
-- ============================================================
INSERT INTO layers.amenities (name, amenity_type, amenity_category, geometry, source)
SELECT
    COALESCE(p.display_name, INITCAP(p.community_name), 'Plot ' || p.plot_number),
    CASE
        WHEN p.land_use ILIKE '%school%' OR p.land_use ILIKE '%education%' THEN 'school'
        WHEN p.land_use ILIKE '%hospital%' OR p.land_use ILIKE '%clinic%' OR p.land_use ILIKE '%health%' THEN 'hospital'
        WHEN p.land_use ILIKE '%mosque%' OR p.land_use ILIKE '%worship%' OR p.land_use ILIKE '%religious%' THEN 'mosque'
        WHEN p.land_use ILIKE '%retail%' THEN 'supermarket'
        WHEN p.land_use ILIKE '%commercial%' AND p.plot_area_sqm > 5000 THEN 'mall'
        WHEN p.land_use ILIKE '%recreation%' OR p.land_use ILIKE '%gym%' OR p.land_use ILIKE '%sport%' THEN 'sports_club'
        WHEN p.land_use ILIKE '%park%' OR p.land_use ILIKE '%garden%' THEN 'park'
        WHEN p.land_use ILIKE '%hotel%' THEN 'hotel'
        WHEN p.land_use ILIKE '%parking%' THEN 'parking'
        ELSE 'other'
    END,
    CASE
        WHEN p.land_use ILIKE '%school%' OR p.land_use ILIKE '%education%' THEN 'education'
        WHEN p.land_use ILIKE '%hospital%' OR p.land_use ILIKE '%health%' THEN 'health'
        WHEN p.land_use ILIKE '%mosque%' OR p.land_use ILIKE '%worship%' THEN 'worship'
        WHEN p.land_use ILIKE '%retail%' OR p.land_use ILIKE '%commercial%' THEN 'retail'
        WHEN p.land_use ILIKE '%recreation%' OR p.land_use ILIKE '%sport%' THEN 'recreation'
        WHEN p.land_use ILIKE '%park%' THEN 'recreation'
        WHEN p.land_use ILIKE '%hotel%' THEN 'retail'
        ELSE 'services'
    END,
    ST_Centroid(p.geometry),
    'dda'
FROM bronze.dda_plots p
WHERE p.geometry IS NOT NULL
  AND (
      p.land_use ILIKE '%school%'     OR p.land_use ILIKE '%hospital%'
      OR p.land_use ILIKE '%mosque%'  OR p.land_use ILIKE '%retail%'
      OR p.land_use ILIKE '%recreation%' OR p.land_use ILIKE '%park%'
      OR p.land_use ILIKE '%hotel%'   OR p.land_use ILIKE '%sport%'
      OR p.land_use ILIKE '%worship%' OR p.land_use ILIKE '%education%'
      OR p.land_use ILIKE '%clinic%'  OR p.land_use ILIKE '%health%'
  )
ON CONFLICT (google_place_id) DO NOTHING;

-- ============================================================
-- LAYER 4b: AMENITY SCORES PER PLOT
-- For each residential plot, compute amenity access score
--
-- Scoring weights:
--   Schools within 1km:    8 pts each (max 3)  = 24
--   Hospitals within 2km: 10 pts each (max 2)  = 20
--   Supermarkets 500m:     8 pts each (max 2)  = 16
--   Metro within 1km:     15 pts (max 1)       = 15
--   Mosque 500m:           5 pts each (max 2)  = 10
--   Parks within 1km:      5 pts each (max 3)  = 15
--   Food/restaurants 500m: 3 pts each (max 5)  = 15
--   Total possible:                             = 115 (capped at 100)
-- ============================================================

CREATE TABLE IF NOT EXISTS gold.amenity_scores (
    plot_number         TEXT PRIMARY KEY,
    -- Counts within radius
    schools_500m        INTEGER DEFAULT 0,
    schools_1km         INTEGER DEFAULT 0,
    hospitals_2km       INTEGER DEFAULT 0,
    supermarkets_500m   INTEGER DEFAULT 0,
    mosques_500m        INTEGER DEFAULT 0,
    restaurants_500m    INTEGER DEFAULT 0,
    gyms_1km            INTEGER DEFAULT 0,
    parks_1km           INTEGER DEFAULT 0,
    malls_2km           INTEGER DEFAULT 0,
    metro_1km           INTEGER DEFAULT 0,
    -- Quality
    avg_rating_500m     NUMERIC,
    -- Composite
    amenity_score       INTEGER,
    amenity_grade       TEXT,   -- A / B / C / D / F
    updated_at          TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Compute amenity scores for residential plots
-- Uses subqueries to count amenities within radius
-- ============================================================
INSERT INTO gold.amenity_scores (
    plot_number,
    schools_500m, schools_1km, hospitals_2km,
    supermarkets_500m, mosques_500m, restaurants_500m,
    gyms_1km, parks_1km, malls_2km, metro_1km,
    avg_rating_500m, amenity_score, amenity_grade
)
SELECT
    p.plot_number,

    -- Count amenities at various radii
    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'school'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'school'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'hospital'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type IN ('supermarket', 'convenience')
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'mosque'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_category = 'food'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type IN ('gym', 'sports_club')
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'park'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'mall'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)),

    (SELECT COUNT(*) FROM layers.amenities a
     WHERE a.amenity_type = 'metro_station'
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)),

    -- Avg rating of nearby amenities
    (SELECT AVG(a.rating) FROM layers.amenities a
     WHERE a.rating IS NOT NULL
       AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)),

    -- Composite score (weighted, capped at 100)
    LEAST(100, (
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'school' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 8 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'hospital' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)), 2) * 10 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type IN ('supermarket','convenience') AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 8 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'mosque' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 5 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_category = 'food' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 5) * 3 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'metro_station' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 1) * 15 +
        LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'park' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 5
    )),

    -- Grade based on composite score
    CASE
        WHEN LEAST(100, (
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'school' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'hospital' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)), 2) * 10 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type IN ('supermarket','convenience') AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'mosque' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 5 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_category = 'food' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 5) * 3 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'metro_station' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 1) * 15 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'park' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 5
        )) >= 80 THEN 'A'
        WHEN LEAST(100, (
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'school' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'hospital' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)), 2) * 10 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type IN ('supermarket','convenience') AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'mosque' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 5 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_category = 'food' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 5) * 3 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'metro_station' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 1) * 15 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'park' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 5
        )) >= 60 THEN 'B'
        WHEN LEAST(100, (
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'school' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'hospital' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)), 2) * 10 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type IN ('supermarket','convenience') AND ST_DWithin(p.centroid::geography, a.geometry::geography, 500)), 2) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'metro_station' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 1) * 15
        )) >= 40 THEN 'C'
        WHEN LEAST(100, (
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'school' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 1000)), 3) * 8 +
            LEAST((SELECT COUNT(*) FROM layers.amenities a WHERE a.amenity_type = 'hospital' AND ST_DWithin(p.centroid::geography, a.geometry::geography, 2000)), 2) * 10
        )) >= 20 THEN 'D'
        ELSE 'F'
    END

FROM bronze.dda_plots p
WHERE p.land_use_category IN ('RESIDENTIAL', 'MIXED USE')
  AND p.centroid IS NOT NULL
ON CONFLICT (plot_number) DO UPDATE SET
    schools_500m = EXCLUDED.schools_500m,
    schools_1km = EXCLUDED.schools_1km,
    hospitals_2km = EXCLUDED.hospitals_2km,
    supermarkets_500m = EXCLUDED.supermarkets_500m,
    mosques_500m = EXCLUDED.mosques_500m,
    restaurants_500m = EXCLUDED.restaurants_500m,
    gyms_1km = EXCLUDED.gyms_1km,
    parks_1km = EXCLUDED.parks_1km,
    malls_2km = EXCLUDED.malls_2km,
    metro_1km = EXCLUDED.metro_1km,
    avg_rating_500m = EXCLUDED.avg_rating_500m,
    amenity_score = EXCLUDED.amenity_score,
    amenity_grade = EXCLUDED.amenity_grade,
    updated_at = now();
