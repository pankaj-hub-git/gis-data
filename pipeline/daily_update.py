#!/usr/bin/env python3
"""
Step 7: Daily incremental update pipeline.

Strategy:
  1. Check if the API supports lastEditDate queries (ideal for incremental)
  2. If not, compare total record count with our DB count
  3. If counts differ, do a full re-scan
  4. Re-run enrichment after any updates
  5. Log all changes detected

Usage:
    # Run daily update
    python -m pipeline.daily_update

    # Force full re-sync regardless of counts
    python -m pipeline.daily_update --force

Schedule via cron (2 AM GST = 10 PM UTC):
    0 22 * * * cd /path/to/gis-data && /path/to/python -m pipeline.daily_update >> logs/cron.log 2>&1
"""

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

from pipeline.config import SERVICES
from pipeline.db import get_conn, init_schema, run_sql_file
from pipeline.http_client import fetch_json
from pipeline.ingest_plots import ingest_full_dubai

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/daily_update.log"),
    ],
)
logger = logging.getLogger(__name__)


def get_api_record_count() -> int:
    """Get total plot count from the API."""
    svc = SERVICES["basic_land_base"]
    url = f"{svc['url']}/{svc['layers']['plot']}/query"
    data = fetch_json(url, {"where": "1=1", "returnCountOnly": "true"})
    return data.get("count", 0)


def get_db_record_count() -> int:
    """Get total plot count from our database."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots")
            return cur.fetchone()[0]


def check_edit_tracking_support() -> dict | None:
    """Check if the layer supports edit tracking (lastEditDate queries)."""
    svc = SERVICES["basic_land_base"]
    url = f"{svc['url']}/{svc['layers']['plot']}"
    meta = fetch_json(url)

    edit_fields = meta.get("editFieldsInfo")
    has_tracking = meta.get("hasAttachments") is not None  # proxy for advanced capabilities
    supports_query = "Query" in (meta.get("capabilities", "") or "")

    info = {
        "editFieldsInfo": edit_fields,
        "supportsAdvancedQueries": meta.get("supportsAdvancedQueries"),
        "supportsStatistics": meta.get("supportsStatistics"),
    }

    if edit_fields:
        logger.info("Edit tracking supported: %s", edit_fields)
        return info

    logger.info("Edit tracking not available — will use count comparison")
    return None


def fetch_recently_modified(edit_date_field: str, since: datetime) -> list[dict]:
    """Query features modified since a given date."""
    from pipeline.http_client import fetch_geojson

    svc = SERVICES["basic_land_base"]
    url = f"{svc['url']}/{svc['layers']['plot']}/query"
    max_records = svc["max_record_count"]

    # ArcGIS date format
    since_epoch_ms = int(since.timestamp() * 1000)
    where = f"{edit_date_field} >= {since_epoch_ms}"

    all_features = []
    offset = 0

    while True:
        params = {
            "where": where,
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "resultOffset": str(offset),
            "resultRecordCount": str(max_records),
            "orderByFields": "OBJECTID ASC",
        }

        data = fetch_geojson(url, params)
        features = data.get("features", [])
        if not features:
            break

        all_features.extend(features)
        if len(features) < max_records:
            break
        offset += max_records

    return all_features


def run_incremental_update(edit_info: dict):
    """Use edit tracking to fetch only recently modified records."""
    from pipeline.field_map import PLOT_FIELD_MAP, auto_match_fields
    from pipeline.ingest_plots import detect_field_map, ingest_features

    edit_fields = edit_info.get("editFieldsInfo", {})
    edit_date_field = edit_fields.get("editDateField") or edit_fields.get("lastEditDateField")

    if not edit_date_field:
        logger.warning("No edit date field found, falling back to full scan")
        return False

    # Get the last successful ingestion time
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT MAX(finished_at) FROM bronze.ingestion_log
                WHERE layer = 'dda_plots' AND status = 'completed'
            """)
            row = cur.fetchone()
            last_run = row[0] if row and row[0] else None

    if not last_run:
        logger.info("No previous successful run found, need full scan")
        return False

    logger.info("Fetching records modified since %s", last_run)
    features = fetch_recently_modified(edit_date_field, last_run)
    logger.info("Found %d modified records", len(features))

    if features:
        field_map = detect_field_map()
        upserted = ingest_features(features, field_map)
        logger.info("Upserted %d modified records", upserted)

    return True


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="Daily update pipeline")
    parser.add_argument("--force", action="store_true", help="Force full re-sync")
    args = parser.parse_args()

    start_time = datetime.now(timezone.utc)
    logger.info("=" * 60)
    logger.info("DAILY UPDATE STARTED AT %s", start_time.isoformat())
    logger.info("=" * 60)

    init_schema()

    needs_full_scan = args.force

    if not needs_full_scan:
        # Strategy 1: Try edit tracking
        edit_info = check_edit_tracking_support()
        if edit_info:
            try:
                success = run_incremental_update(edit_info)
                if not success:
                    needs_full_scan = True
            except Exception as exc:
                logger.error("Incremental update failed: %s", exc)
                needs_full_scan = True
        else:
            # Strategy 2: Compare record counts
            api_count = get_api_record_count()
            db_count = get_db_record_count()
            logger.info("API count: %d, DB count: %d", api_count, db_count)

            if api_count != db_count:
                logger.info("Count mismatch (%+d), triggering full scan", api_count - db_count)
                needs_full_scan = True
            else:
                logger.info("Counts match, no update needed")

    if needs_full_scan:
        logger.info("Running full spatial tile scan")
        # Clear progress file to start fresh (unless resuming)
        progress_file = Path("logs/tile_progress.json")
        if progress_file.exists() and not args.force:
            # If there's existing progress, resume it
            ingest_full_dubai(resume=True)
        else:
            if progress_file.exists():
                progress_file.unlink()
            ingest_full_dubai(resume=False)

    # Run enrichment
    logger.info("Running enrichment")
    sql_path = Path(__file__).parent.parent / "sql" / "002_enrichment.sql"
    run_sql_file(sql_path)

    # Log summary
    db_count = get_db_record_count()
    end_time = datetime.now(timezone.utc)
    logger.info("=" * 60)
    logger.info("DAILY UPDATE COMPLETED AT %s", end_time.isoformat())
    logger.info("Total plots in DB: %d", db_count)
    logger.info("=" * 60)

    # Write status file for monitoring
    status = {
        "last_run": end_time.isoformat(),
        "total_plots": db_count,
        "full_scan": needs_full_scan,
        "duration_seconds": (end_time - start_time).total_seconds(),
    }
    Path("logs/daily_status.json").write_text(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
