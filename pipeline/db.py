"""Database connection and helpers for PostGIS/Supabase."""

import json
import logging
from contextlib import contextmanager
from pathlib import Path

import psycopg2
import psycopg2.extras

from pipeline.config import DATABASE_URL

logger = logging.getLogger(__name__)


@contextmanager
def get_conn():
    """Yield a psycopg2 connection, committing on success, rolling back on error."""
    conn = psycopg2.connect(DATABASE_URL)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def run_sql_file(path: str | Path):
    """Execute a SQL file against the database."""
    sql = Path(path).read_text()
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
    logger.info("Executed SQL file: %s", path)


def init_schema():
    """Create the bronze schema and all tables."""
    sql_dir = Path(__file__).parent.parent / "sql"
    run_sql_file(sql_dir / "001_schema.sql")
    logger.info("Schema initialized successfully")


def upsert_plot(cur, feature: dict, field_map: dict):
    """Upsert a single plot feature into bronze.dda_plots.

    field_map: maps our DB column names to the ArcGIS field names found in
    the feature properties. Built dynamically after discovery.
    """
    props = feature.get("properties", {})
    geom = feature.get("geometry")
    geojson_str = json.dumps(geom) if geom else None

    # Extract values using the field map, falling back to None
    def get(db_col: str):
        api_field = field_map.get(db_col)
        if api_field is None:
            return None
        return props.get(api_field)

    # Parse epoch milliseconds to timestamp if present
    def parse_epoch(val):
        if val is None:
            return None
        if isinstance(val, (int, float)) and val > 1_000_000_000:
            # ArcGIS returns epoch milliseconds
            from datetime import datetime, timezone
            return datetime.fromtimestamp(val / 1000, tz=timezone.utc)
        return val

    cur.execute("""
        INSERT INTO bronze.dda_plots (
            objectid, plot_number, old_numbers, project_name, community_name,
            master_developer, plot_area_sqm, plot_area_sqft,
            max_gfa_sqm, max_gfa_sqft, max_height, max_coverage,
            land_use, site_plan_issue_date, site_plan_expiry_date,
            setback_front_bldg, setback_rear_bldg, setback_left_bldg, setback_right_bldg,
            setback_front_podium, setback_rear_podium, setback_left_podium, setback_right_podium,
            status, raw_attributes, geometry
        ) VALUES (
            %(objectid)s, %(plot_number)s, %(old_numbers)s, %(project_name)s, %(community_name)s,
            %(master_developer)s, %(plot_area_sqm)s, %(plot_area_sqft)s,
            %(max_gfa_sqm)s, %(max_gfa_sqft)s, %(max_height)s, %(max_coverage)s,
            %(land_use)s, %(site_plan_issue_date)s, %(site_plan_expiry_date)s,
            %(setback_front_bldg)s, %(setback_rear_bldg)s, %(setback_left_bldg)s, %(setback_right_bldg)s,
            %(setback_front_podium)s, %(setback_rear_podium)s, %(setback_left_podium)s, %(setback_right_podium)s,
            %(status)s, %(raw_attributes)s,
            CASE WHEN %(geojson)s IS NOT NULL
                 THEN ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)
                 ELSE NULL END
        )
        ON CONFLICT (objectid) DO UPDATE SET
            plot_number = EXCLUDED.plot_number,
            old_numbers = EXCLUDED.old_numbers,
            project_name = EXCLUDED.project_name,
            community_name = EXCLUDED.community_name,
            master_developer = EXCLUDED.master_developer,
            plot_area_sqm = EXCLUDED.plot_area_sqm,
            plot_area_sqft = EXCLUDED.plot_area_sqft,
            max_gfa_sqm = EXCLUDED.max_gfa_sqm,
            max_gfa_sqft = EXCLUDED.max_gfa_sqft,
            max_height = EXCLUDED.max_height,
            max_coverage = EXCLUDED.max_coverage,
            land_use = EXCLUDED.land_use,
            site_plan_issue_date = EXCLUDED.site_plan_issue_date,
            site_plan_expiry_date = EXCLUDED.site_plan_expiry_date,
            setback_front_bldg = EXCLUDED.setback_front_bldg,
            setback_rear_bldg = EXCLUDED.setback_rear_bldg,
            setback_left_bldg = EXCLUDED.setback_left_bldg,
            setback_right_bldg = EXCLUDED.setback_right_bldg,
            setback_front_podium = EXCLUDED.setback_front_podium,
            setback_rear_podium = EXCLUDED.setback_rear_podium,
            setback_left_podium = EXCLUDED.setback_left_podium,
            setback_right_podium = EXCLUDED.setback_right_podium,
            status = EXCLUDED.status,
            raw_attributes = EXCLUDED.raw_attributes,
            geometry = EXCLUDED.geometry,
            updated_at = now()
    """, {
        "objectid": get("objectid"),
        "plot_number": get("plot_number"),
        "old_numbers": get("old_numbers"),
        "project_name": get("project_name"),
        "community_name": get("community_name"),
        "master_developer": get("master_developer"),
        "plot_area_sqm": get("plot_area_sqm"),
        "plot_area_sqft": get("plot_area_sqft"),
        "max_gfa_sqm": get("max_gfa_sqm"),
        "max_gfa_sqft": get("max_gfa_sqft"),
        "max_height": get("max_height"),
        "max_coverage": get("max_coverage"),
        "land_use": get("land_use"),
        "site_plan_issue_date": parse_epoch(get("site_plan_issue_date")),
        "site_plan_expiry_date": parse_epoch(get("site_plan_expiry_date")),
        "setback_front_bldg": get("setback_front_bldg"),
        "setback_rear_bldg": get("setback_rear_bldg"),
        "setback_left_bldg": get("setback_left_bldg"),
        "setback_right_bldg": get("setback_right_bldg"),
        "setback_front_podium": get("setback_front_podium"),
        "setback_rear_podium": get("setback_rear_podium"),
        "setback_left_podium": get("setback_left_podium"),
        "setback_right_podium": get("setback_right_podium"),
        "status": get("status"),
        "raw_attributes": json.dumps(props),
        "geojson": geojson_str,
    })


def upsert_project(cur, feature: dict, field_map: dict):
    """Upsert a single project boundary into bronze.dda_projects."""
    props = feature.get("properties", {})
    geom = feature.get("geometry")
    geojson_str = json.dumps(geom) if geom else None

    def get(db_col: str):
        api_field = field_map.get(db_col)
        return props.get(api_field) if api_field else None

    cur.execute("""
        INSERT INTO bronze.dda_projects (
            objectid, project_name, project_number, master_developer,
            status, raw_attributes, geometry
        ) VALUES (
            %(objectid)s, %(project_name)s, %(project_number)s, %(master_developer)s,
            %(status)s, %(raw_attributes)s,
            CASE WHEN %(geojson)s IS NOT NULL
                 THEN ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)
                 ELSE NULL END
        )
        ON CONFLICT (objectid) DO UPDATE SET
            project_name = EXCLUDED.project_name,
            project_number = EXCLUDED.project_number,
            master_developer = EXCLUDED.master_developer,
            status = EXCLUDED.status,
            raw_attributes = EXCLUDED.raw_attributes,
            geometry = EXCLUDED.geometry,
            updated_at = now()
    """, {
        "objectid": get("objectid"),
        "project_name": get("project_name"),
        "project_number": get("project_number"),
        "master_developer": get("master_developer"),
        "status": get("status"),
        "raw_attributes": json.dumps(props),
        "geojson": geojson_str,
    })


def upsert_construction(cur, feature: dict, field_map: dict):
    """Upsert a single construction status feature."""
    props = feature.get("properties", {})
    geom = feature.get("geometry")
    geojson_str = json.dumps(geom) if geom else None

    def get(db_col: str):
        api_field = field_map.get(db_col)
        return props.get(api_field) if api_field else None

    cur.execute("""
        INSERT INTO bronze.dda_construction_status (
            objectid, project_name, plot_number, construction_status,
            permit_number, contractor, consultant,
            raw_attributes, geometry
        ) VALUES (
            %(objectid)s, %(project_name)s, %(plot_number)s, %(construction_status)s,
            %(permit_number)s, %(contractor)s, %(consultant)s,
            %(raw_attributes)s,
            CASE WHEN %(geojson)s IS NOT NULL
                 THEN ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)
                 ELSE NULL END
        )
        ON CONFLICT (objectid) DO UPDATE SET
            project_name = EXCLUDED.project_name,
            plot_number = EXCLUDED.plot_number,
            construction_status = EXCLUDED.construction_status,
            permit_number = EXCLUDED.permit_number,
            contractor = EXCLUDED.contractor,
            consultant = EXCLUDED.consultant,
            raw_attributes = EXCLUDED.raw_attributes,
            geometry = EXCLUDED.geometry,
            updated_at = now()
    """, {
        "objectid": get("objectid"),
        "project_name": get("project_name"),
        "plot_number": get("plot_number"),
        "construction_status": get("construction_status"),
        "permit_number": get("permit_number"),
        "contractor": get("contractor"),
        "consultant": get("consultant"),
        "raw_attributes": json.dumps(props),
        "geojson": geojson_str,
    })


def log_ingestion_start(layer: str, tiles_total: int = 0) -> int:
    """Create an ingestion log entry, return its ID."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO bronze.ingestion_log (layer, tiles_total)
                VALUES (%s, %s) RETURNING id
            """, (layer, tiles_total))
            row = cur.fetchone()
            return row[0]


def log_ingestion_progress(log_id: int, records_fetched: int, records_upserted: int, tiles_completed: int):
    """Update progress on an ingestion log entry."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE bronze.ingestion_log
                SET records_fetched = %s, records_upserted = %s, tiles_completed = %s
                WHERE id = %s
            """, (records_fetched, records_upserted, tiles_completed, log_id))


def log_ingestion_end(log_id: int, status: str, error_message: str | None = None):
    """Finalize an ingestion log entry."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE bronze.ingestion_log
                SET finished_at = now(), status = %s, error_message = %s
                WHERE id = %s
            """, (status, error_message, log_id))
