-- DDA GIS Pipeline: Bronze layer schema
-- Run against Supabase/PostGIS database

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS bronze;

-- ============================================================
-- Ingestion tracking
-- ============================================================
CREATE TABLE IF NOT EXISTS bronze.ingestion_log (
    id              BIGSERIAL PRIMARY KEY,
    run_id          UUID NOT NULL DEFAULT gen_random_uuid(),
    layer           TEXT NOT NULL,          -- e.g. 'dda_plots', 'dda_projects'
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'running',  -- running | completed | failed
    records_fetched INTEGER DEFAULT 0,
    records_upserted INTEGER DEFAULT 0,
    tiles_completed INTEGER DEFAULT 0,
    tiles_total     INTEGER DEFAULT 0,
    error_message   TEXT,
    metadata        JSONB DEFAULT '{}'
);

-- ============================================================
-- Plot data (Layer 2 of BASIC_LAND_BASE)
-- ============================================================
CREATE TABLE IF NOT EXISTS bronze.dda_plots (
    id                  BIGSERIAL PRIMARY KEY,
    objectid            INTEGER,
    plot_number         TEXT,
    old_numbers         TEXT,
    project_name        TEXT,
    community_name      TEXT,
    master_developer    TEXT,
    plot_area_sqm       DOUBLE PRECISION,
    plot_area_sqft      DOUBLE PRECISION,
    max_gfa_sqm         DOUBLE PRECISION,
    max_gfa_sqft        DOUBLE PRECISION,
    max_height          TEXT,           -- raw string like "G+P+18"
    max_coverage        DOUBLE PRECISION,
    land_use            TEXT,           -- raw string like "RESIDENTIAL: APARTMENT"
    site_plan_issue_date TIMESTAMPTZ,
    site_plan_expiry_date TIMESTAMPTZ,
    setback_front_bldg  DOUBLE PRECISION,
    setback_rear_bldg   DOUBLE PRECISION,
    setback_left_bldg   DOUBLE PRECISION,
    setback_right_bldg  DOUBLE PRECISION,
    setback_front_podium DOUBLE PRECISION,
    setback_rear_podium  DOUBLE PRECISION,
    setback_left_podium  DOUBLE PRECISION,
    setback_right_podium DOUBLE PRECISION,
    status              TEXT,
    raw_attributes      JSONB,          -- full API response for this feature
    geometry            GEOMETRY(Geometry, 4326),
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_layer        TEXT DEFAULT 'DDA/BASIC_LAND_BASE/MapServer/2',

    CONSTRAINT uq_plots_objectid UNIQUE (objectid)
);

CREATE INDEX IF NOT EXISTS idx_plots_geom ON bronze.dda_plots USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_plots_project ON bronze.dda_plots (project_name);
CREATE INDEX IF NOT EXISTS idx_plots_plot_number ON bronze.dda_plots (plot_number);
CREATE INDEX IF NOT EXISTS idx_plots_land_use ON bronze.dda_plots (land_use);
CREATE INDEX IF NOT EXISTS idx_plots_raw ON bronze.dda_plots USING GIN (raw_attributes);

-- ============================================================
-- Project boundaries (Layer 0 of BASIC_LAND_BASE)
-- ============================================================
CREATE TABLE IF NOT EXISTS bronze.dda_projects (
    id                  BIGSERIAL PRIMARY KEY,
    objectid            INTEGER,
    project_name        TEXT,
    project_number      TEXT,
    master_developer    TEXT,
    status              TEXT,
    raw_attributes      JSONB,
    geometry            GEOMETRY(Geometry, 4326),
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_layer        TEXT DEFAULT 'DDA/BASIC_LAND_BASE/MapServer/0',

    CONSTRAINT uq_projects_objectid UNIQUE (objectid)
);

CREATE INDEX IF NOT EXISTS idx_projects_geom ON bronze.dda_projects USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_projects_name ON bronze.dda_projects (project_name);

-- ============================================================
-- Construction status (Layer 3 of ZonesControl)
-- ============================================================
CREATE TABLE IF NOT EXISTS bronze.dda_construction_status (
    id                  BIGSERIAL PRIMARY KEY,
    objectid            INTEGER,
    project_name        TEXT,
    plot_number         TEXT,
    construction_status TEXT,
    permit_number       TEXT,
    contractor          TEXT,
    consultant          TEXT,
    raw_attributes      JSONB,
    geometry            GEOMETRY(Geometry, 4326),
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_layer        TEXT DEFAULT 'DDA/ZonesControl/MapServer/3',

    CONSTRAINT uq_construction_objectid UNIQUE (objectid)
);

CREATE INDEX IF NOT EXISTS idx_construction_geom ON bronze.dda_construction_status USING GIST (geometry);
CREATE INDEX IF NOT EXISTS idx_construction_project ON bronze.dda_construction_status (project_name);
CREATE INDEX IF NOT EXISTS idx_construction_status ON bronze.dda_construction_status (construction_status);
