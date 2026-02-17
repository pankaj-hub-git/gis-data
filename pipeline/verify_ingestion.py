#!/usr/bin/env python3
"""
Verify ingestion completeness for Business Bay and Dubai Hills.

Compares the DDA ArcGIS API (source of truth) against Supabase DB
to detect missing plots, extra plots, and data quality issues.

Usage:
    # Verify specific projects (default: Business Bay + Dubai Hills)
    python -m pipeline.verify_ingestion

    # Verify custom projects
    python -m pipeline.verify_ingestion --projects "DUBAI HILLS" "BUSINESS BAY" "JUMEIRAH"

    # Output JSON report instead of human-readable
    python -m pipeline.verify_ingestion --json

    # Auto-fix: re-ingest any missing plots
    python -m pipeline.verify_ingestion --fix
"""

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

from pipeline.config import SERVICES
from pipeline.db import get_conn
from pipeline.http_client import fetch_geojson, fetch_json

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/verify_ingestion.log"),
    ],
)
logger = logging.getLogger(__name__)

SVC = SERVICES["basic_land_base"]
QUERY_URL = f"{SVC['url']}/{SVC['layers']['plot']}/query"

DEFAULT_PROJECTS = ["DUBAI HILLS", "BUSINESS BAY"]


def get_api_count(project_name: str) -> int:
    """Get count of plots matching a project from the DDA API."""
    where = f"PROJECT_NAME LIKE '%{project_name}%'"
    data = fetch_json(QUERY_URL, {"where": where, "returnCountOnly": "true"})
    return data.get("count", 0)


def get_api_objectids(project_name: str) -> set[int]:
    """Get all OBJECTIDs for a project from the DDA API."""
    where = f"PROJECT_NAME LIKE '%{project_name}%'"
    data = fetch_json(QUERY_URL, {
        "where": where,
        "returnIdsOnly": "true",
    })
    return set(data.get("objectIds", []) or [])


def get_db_count(project_name: str) -> int:
    """Get count of plots matching a project from the database."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM bronze.dda_plots WHERE project_name LIKE %s",
                (f"%{project_name}%",),
            )
            return cur.fetchone()[0]


def get_db_objectids(project_name: str) -> set[int]:
    """Get all OBJECTIDs for a project from the database."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT objectid FROM bronze.dda_plots WHERE project_name LIKE %s",
                (f"%{project_name}%",),
            )
            return {row[0] for row in cur.fetchall()}


def get_db_quality_stats(project_name: str) -> dict:
    """Get data quality stats for a project from the database."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    COUNT(*)                                          AS total,
                    COUNT(*) FILTER (WHERE geometry IS NULL)          AS missing_geometry,
                    COUNT(*) FILTER (WHERE plot_number IS NULL)       AS missing_plot_number,
                    COUNT(*) FILTER (WHERE land_use IS NULL)          AS missing_land_use,
                    COUNT(*) FILTER (WHERE max_height IS NULL)        AS missing_max_height,
                    COUNT(*) FILTER (WHERE plot_area_sqm IS NULL OR plot_area_sqm = 0) AS missing_area,
                    COUNT(*) FILTER (WHERE max_gfa_sqm IS NULL OR max_gfa_sqm = 0)    AS missing_gfa,
                    MIN(ingested_at)                                  AS earliest_ingested,
                    MAX(updated_at)                                   AS latest_updated
                FROM bronze.dda_plots
                WHERE project_name LIKE %s
            """, (f"%{project_name}%",))
            row = cur.fetchone()
            return {
                "total": row[0],
                "missing_geometry": row[1],
                "missing_plot_number": row[2],
                "missing_land_use": row[3],
                "missing_max_height": row[4],
                "missing_area": row[5],
                "missing_gfa": row[6],
                "earliest_ingested": row[7].isoformat() if row[7] else None,
                "latest_updated": row[8].isoformat() if row[8] else None,
            }


def verify_project(project_name: str) -> dict:
    """Run full verification for a single project. Returns a report dict."""
    logger.info("=" * 50)
    logger.info("Verifying: %s", project_name)
    logger.info("=" * 50)

    # Step 1: Count comparison
    api_count = get_api_count(project_name)
    db_count = get_db_count(project_name)
    count_match = api_count == db_count

    logger.info("API count: %d", api_count)
    logger.info("DB  count: %d", db_count)
    logger.info("Match: %s", "YES" if count_match else "NO — MISMATCH")

    # Step 2: OBJECTID-level comparison (identifies exact missing/extra plots)
    api_ids = get_api_objectids(project_name)
    db_ids = get_db_objectids(project_name)

    missing_from_db = sorted(api_ids - db_ids)   # In API but not DB
    extra_in_db = sorted(db_ids - api_ids)        # In DB but not API (deleted upstream?)

    if missing_from_db:
        logger.warning("  MISSING from DB (%d plots): %s",
                        len(missing_from_db),
                        missing_from_db[:20])  # Show first 20
    if extra_in_db:
        logger.warning("  EXTRA in DB (%d plots, possibly deleted upstream): %s",
                        len(extra_in_db),
                        extra_in_db[:20])

    # Step 3: Data quality check
    quality = get_db_quality_stats(project_name) if db_count > 0 else {}

    if quality:
        issues = []
        if quality["missing_geometry"] > 0:
            issues.append(f"{quality['missing_geometry']} plots without geometry")
        if quality["missing_plot_number"] > 0:
            issues.append(f"{quality['missing_plot_number']} plots without plot_number")
        if quality["missing_area"] > 0:
            issues.append(f"{quality['missing_area']} plots without area")
        if quality["missing_gfa"] > 0:
            issues.append(f"{quality['missing_gfa']} plots without GFA")

        if issues:
            logger.warning("  Data quality issues: %s", "; ".join(issues))
        else:
            logger.info("  Data quality: all key fields populated")

    # Build report
    report = {
        "project": project_name,
        "api_count": api_count,
        "db_count": db_count,
        "counts_match": count_match,
        "missing_from_db": missing_from_db,
        "extra_in_db": extra_in_db,
        "missing_count": len(missing_from_db),
        "extra_count": len(extra_in_db),
        "quality": quality,
        "is_complete": count_match and len(missing_from_db) == 0,
    }

    status = "COMPLETE" if report["is_complete"] else "INCOMPLETE"
    logger.info("  Status: %s", status)

    return report


def fix_missing_plots(report: dict):
    """Re-ingest any plots that are in the API but missing from the DB."""
    from pipeline.ingest_plots import detect_field_map, ingest_features, query_paginated

    missing = report.get("missing_from_db", [])
    if not missing:
        logger.info("No missing plots to fix for %s", report["project"])
        return

    logger.info("Re-ingesting %d missing plots for %s", len(missing), report["project"])
    field_map = detect_field_map()

    # Fetch missing plots in batches by OBJECTID
    batch_size = 100
    total_upserted = 0

    for i in range(0, len(missing), batch_size):
        batch_ids = missing[i:i + batch_size]
        id_list = ",".join(str(oid) for oid in batch_ids)
        where = f"OBJECTID IN ({id_list})"

        features = query_paginated(where)
        if features:
            upserted = ingest_features(features, field_map)
            total_upserted += upserted
            logger.info("  Batch %d: fetched %d, upserted %d",
                        i // batch_size + 1, len(features), upserted)

    logger.info("Fixed %d missing plots for %s", total_upserted, report["project"])


def verify_all(project_names: list[str], fix: bool = False) -> list[dict]:
    """Verify all projects and return combined report."""
    reports = []
    for name in project_names:
        report = verify_project(name)
        reports.append(report)

        if fix and not report["is_complete"]:
            fix_missing_plots(report)
            # Re-verify after fix
            report_after = verify_project(name)
            report["after_fix"] = report_after
            reports[-1] = report

    # Summary
    all_complete = all(r["is_complete"] for r in reports)
    total_api = sum(r["api_count"] for r in reports)
    total_db = sum(r["db_count"] for r in reports)
    total_missing = sum(r["missing_count"] for r in reports)

    logger.info("")
    logger.info("=" * 50)
    logger.info("VERIFICATION SUMMARY")
    logger.info("=" * 50)
    logger.info("Projects checked: %s", ", ".join(project_names))
    logger.info("Total API plots:  %d", total_api)
    logger.info("Total DB plots:   %d", total_db)
    logger.info("Missing plots:    %d", total_missing)
    logger.info("Overall status:   %s", "ALL COMPLETE" if all_complete else "INCOMPLETE")

    return reports


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="Verify ingestion completeness")
    parser.add_argument("--projects", nargs="+", default=DEFAULT_PROJECTS,
                        help="Project names to verify (default: DUBAI HILLS, BUSINESS BAY)")
    parser.add_argument("--json", action="store_true", help="Output JSON report")
    parser.add_argument("--fix", action="store_true",
                        help="Auto re-ingest any missing plots")
    args = parser.parse_args()

    reports = verify_all(args.projects, fix=args.fix)

    # Save report
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = Path(f"logs/verify_report_{timestamp}.json")
    report_data = {
        "timestamp": timestamp,
        "projects": args.projects,
        "reports": reports,
        "all_complete": all(r["is_complete"] for r in reports),
    }
    report_path.write_text(json.dumps(report_data, indent=2, default=str))
    logger.info("Report saved to %s", report_path)

    if args.json:
        print(json.dumps(report_data, indent=2, default=str))

    # Exit with non-zero if incomplete (useful for CI/cron alerting)
    if not report_data["all_complete"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
