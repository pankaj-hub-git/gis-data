-- ============================================================
-- Project Popular Names — DLD Pulse / Market Name Resolution
--
-- PROBLEM:
--   DDA uses official project names like "DUBAI HILLS ESTATE" or
--   "BUSINESS BAY" which are master-plan level identifiers.
--   But the market, DLD Pulse, and investors use marketing names
--   like "Park Heights", "Collective 2.0", "The Opus by Omniyat".
--
--   One DDA project can contain dozens of marketed sub-projects.
--   One marketed project can span multiple DDA plot numbers.
--
-- THIS TABLE bridges DDA official names → market popular names
-- using data from DLD Pulse, RERA, and developer marketing.
-- ============================================================

CREATE TABLE IF NOT EXISTS bronze.project_popular_names (
    id                  BIGSERIAL PRIMARY KEY,
    dda_project_name    TEXT NOT NULL,          -- Official DDA project name (e.g. "DUBAI HILLS ESTATE")
    popular_name        TEXT NOT NULL,          -- Market/DLD Pulse name (e.g. "Park Heights 1")
    developer           TEXT,                   -- Developer marketing the project
    source              TEXT NOT NULL,          -- DLD_PULSE | RERA | MARKETING | MANUAL
    dld_project_id      TEXT,                   -- DLD Pulse project identifier (if available)
    rera_number         TEXT,                   -- RERA registration number
    plot_numbers        TEXT[],                 -- DDA plot numbers this popular name maps to
    community           TEXT,                   -- Sub-community (e.g. "Park Heights", "Golf Suites")
    asset_type          TEXT,                   -- APARTMENT | VILLA | TOWNHOUSE | HOTEL | OFFICE | MIXED
    status              TEXT,                   -- COMPLETED | UNDER_CONSTRUCTION | OFF_PLAN | PLANNED
    handover_date       DATE,                   -- Expected or actual handover
    confidence          DOUBLE PRECISION DEFAULT 1.0, -- Match confidence (1.0 = verified, 0.5 = fuzzy)
    match_method        TEXT DEFAULT 'EXACT',   -- EXACT | CONTAINS | FUZZY | MANUAL
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_popular_name UNIQUE (dda_project_name, popular_name)
);

CREATE INDEX IF NOT EXISTS idx_popular_dda ON bronze.project_popular_names (dda_project_name);
CREATE INDEX IF NOT EXISTS idx_popular_name ON bronze.project_popular_names (popular_name);
CREATE INDEX IF NOT EXISTS idx_popular_dld_id ON bronze.project_popular_names (dld_project_id);

-- ============================================================
-- Enable fuzzy matching with pg_trgm (trigram similarity)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_popular_name_trgm
    ON bronze.project_popular_names USING GIN (popular_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_popular_dda_trgm
    ON bronze.project_popular_names USING GIN (dda_project_name gin_trgm_ops);

-- ============================================================
-- Seed: DUBAI HILLS ESTATE popular names (DLD Pulse)
-- ============================================================
INSERT INTO bronze.project_popular_names
    (dda_project_name, popular_name, developer, source, community, asset_type, status)
VALUES
    ('DUBAI HILLS ESTATE', 'Park Heights 1', 'Emaar Properties', 'DLD_PULSE', 'Park Heights', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Park Heights 2', 'Emaar Properties', 'DLD_PULSE', 'Park Heights', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Park Point', 'Emaar Properties', 'DLD_PULSE', 'Park Point', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Golf Suites', 'Emaar Properties', 'DLD_PULSE', 'Golf Suites', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Collective 2.0', 'Emaar Properties', 'DLD_PULSE', 'Collective', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Golf Place', 'Emaar Properties', 'DLD_PULSE', 'Golf Place', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Golf Place Terraces', 'Emaar Properties', 'DLD_PULSE', 'Golf Place', 'TOWNHOUSE', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Maple at Dubai Hills Estate', 'Emaar Properties', 'DLD_PULSE', 'Maple', 'TOWNHOUSE', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Club Villas at Dubai Hills', 'Emaar Properties', 'DLD_PULSE', 'Club Villas', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Sidra Villas', 'Emaar Properties', 'DLD_PULSE', 'Sidra', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Sidra Villas II', 'Emaar Properties', 'DLD_PULSE', 'Sidra', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Sidra Villas III', 'Emaar Properties', 'DLD_PULSE', 'Sidra', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'GOLFVILLE', 'Emaar Properties', 'DLD_PULSE', 'Golfville', 'APARTMENT', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Ellington House', 'Ellington Properties', 'DLD_PULSE', 'Ellington', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('DUBAI HILLS ESTATE', 'Elora by Emaar', 'Emaar Properties', 'DLD_PULSE', 'Elora', 'APARTMENT', 'OFF_PLAN'),
    ('DUBAI HILLS ESTATE', 'Golf Hillside', 'Emaar Properties', 'DLD_PULSE', 'Golf Hillside', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('DUBAI HILLS ESTATE', 'Park Field', 'Emaar Properties', 'DLD_PULSE', 'Park Field', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('DUBAI HILLS ESTATE', 'Fairway Villas', 'Emaar Properties', 'DLD_PULSE', 'Fairway', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Fairway Villas 2', 'Emaar Properties', 'DLD_PULSE', 'Fairway', 'VILLA', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Dubai Hills Mall', 'Emaar Properties', 'DLD_PULSE', 'Dubai Hills Mall', 'MIXED', 'COMPLETED'),
    ('DUBAI HILLS ESTATE', 'Park Ridge', 'Emaar Properties', 'DLD_PULSE', 'Park Ridge', 'APARTMENT', 'OFF_PLAN'),
    ('DUBAI HILLS ESTATE', 'Park Horizon', 'Emaar Properties', 'DLD_PULSE', 'Park Horizon', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('DUBAI HILLS ESTATE', 'Golf Grand', 'Emaar Properties', 'DLD_PULSE', 'Golf Grand', 'APARTMENT', 'OFF_PLAN'),
    ('DUBAI HILLS ESTATE', 'Murjan by Emaar', 'Emaar Properties', 'DLD_PULSE', 'Murjan', 'APARTMENT', 'OFF_PLAN')
ON CONFLICT (dda_project_name, popular_name) DO UPDATE SET
    developer = EXCLUDED.developer,
    community = EXCLUDED.community,
    asset_type = EXCLUDED.asset_type,
    status = EXCLUDED.status,
    updated_at = now();

-- ============================================================
-- Seed: BUSINESS BAY popular names (DLD Pulse)
-- ============================================================
INSERT INTO bronze.project_popular_names
    (dda_project_name, popular_name, developer, source, community, asset_type, status)
VALUES
    ('BUSINESS BAY', 'The Opus by Omniyat', 'Omniyat', 'DLD_PULSE', 'Business Bay', 'MIXED', 'COMPLETED'),
    ('BUSINESS BAY', 'Paramount Tower Hotel & Residences', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'HOTEL', 'COMPLETED'),
    ('BUSINESS BAY', 'Executive Towers', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Ubora Tower 1', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Ubora Tower 2', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Bay Square', 'Dubai Properties', 'DLD_PULSE', 'Bay Square', 'MIXED', 'COMPLETED'),
    ('BUSINESS BAY', 'Merano Tower', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Claren Tower 1', 'Emaar Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Claren Tower 2', 'Emaar Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Peninsula by Select Group', 'Select Group', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Avanti Tower', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Noora Tower', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'The Pad by Omniyat', 'Omniyat', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'The Binary by Omniyat', 'Omniyat', 'DLD_PULSE', 'Business Bay', 'OFFICE', 'COMPLETED'),
    ('BUSINESS BAY', 'SLS Dubai Hotel & Residences', 'WH Group', 'DLD_PULSE', 'Business Bay', 'HOTEL', 'COMPLETED'),
    ('BUSINESS BAY', 'Bayz by Danube', 'Danube Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('BUSINESS BAY', 'Regalia by Deyaar', 'Deyaar Development', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Aycon City by DAMAC', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('BUSINESS BAY', 'Volta by DAMAC', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('BUSINESS BAY', 'Canal Heights', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'The Sterling by Omniyat', 'Omniyat', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'OFF_PLAN'),
    ('BUSINESS BAY', 'DAMAC Towers by Paramount', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Majestine by DAMAC', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'OFF_PLAN'),
    ('BUSINESS BAY', 'Prive by DAMAC', 'DAMAC Properties', 'DLD_PULSE', 'Business Bay', 'APARTMENT', 'COMPLETED'),
    ('BUSINESS BAY', 'Marasi Business Bay', 'Dubai Properties', 'DLD_PULSE', 'Business Bay', 'MIXED', 'UNDER_CONSTRUCTION')
ON CONFLICT (dda_project_name, popular_name) DO UPDATE SET
    developer = EXCLUDED.developer,
    community = EXCLUDED.community,
    asset_type = EXCLUDED.asset_type,
    status = EXCLUDED.status,
    updated_at = now();

-- ============================================================
-- Seed: DOWNTOWN DUBAI popular names
-- ============================================================
INSERT INTO bronze.project_popular_names
    (dda_project_name, popular_name, developer, source, community, asset_type, status)
VALUES
    ('DOWNTOWN DUBAI', 'Burj Khalifa', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'MIXED', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'The Address Downtown', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'HOTEL', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'The Address Boulevard', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'HOTEL', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'Dubai Mall', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'MIXED', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'Boulevard Point', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'APARTMENT', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'Opera Grand by Emaar', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'APARTMENT', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'Vida Downtown', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'HOTEL', 'COMPLETED'),
    ('DOWNTOWN DUBAI', 'St. Regis The Residences Downtown', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'APARTMENT', 'UNDER_CONSTRUCTION'),
    ('DOWNTOWN DUBAI', 'The Address Residences Sky View', 'Emaar Properties', 'DLD_PULSE', 'Downtown Dubai', 'APARTMENT', 'COMPLETED')
ON CONFLICT (dda_project_name, popular_name) DO UPDATE SET
    developer = EXCLUDED.developer,
    community = EXCLUDED.community,
    asset_type = EXCLUDED.asset_type,
    status = EXCLUDED.status,
    updated_at = now();

-- ============================================================
-- View: Name resolution lookup
-- Quick way to find all popular names for a DDA project
-- ============================================================
CREATE OR REPLACE VIEW bronze.name_lookup AS
SELECT
    ppn.dda_project_name,
    ppn.popular_name,
    ppn.developer,
    ppn.community,
    ppn.asset_type,
    ppn.status,
    ppn.source,
    ppn.confidence,
    ppn.match_method,
    COUNT(DISTINCT p.id) AS matched_plots,
    string_agg(DISTINCT p.plot_number, ', ' ORDER BY p.plot_number) AS plot_numbers
FROM bronze.project_popular_names ppn
LEFT JOIN bronze.dda_plots p
    ON UPPER(p.project_name) LIKE '%' || UPPER(ppn.dda_project_name) || '%'
GROUP BY ppn.dda_project_name, ppn.popular_name, ppn.developer,
         ppn.community, ppn.asset_type, ppn.status, ppn.source,
         ppn.confidence, ppn.match_method
ORDER BY ppn.dda_project_name, ppn.popular_name;
