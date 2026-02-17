#!/usr/bin/env python3
"""
Popular name resolution: DDA official names → DLD Pulse market names.

Manages the project_popular_names reference table and runs the
multi-strategy name enrichment on dda_plots.

Matching strategies (in priority order):
  1. EXACT_PLOT  — plot_numbers array contains this plot's number
  2. PROJECT_MATCH — DDA project_name contains the mapping's dda_project_name
  3. FUZZY — trigram similarity > 0.3 using pg_trgm

Usage:
    # Seed popular names + run enrichment
    python -m pipeline.name_resolver

    # Show resolution quality report
    python -m pipeline.name_resolver --report

    # Search by any name (official or popular)
    python -m pipeline.name_resolver --search "Park Heights"

    # Import popular names from JSON file (DLD Pulse export)
    python -m pipeline.name_resolver --import-file dld_pulse_export.json

    # Output as JSON
    python -m pipeline.name_resolver --report --json
"""

import argparse
import json
import logging
import sys
from pathlib import Path

from pipeline.db import get_conn, run_sql_file

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/name_resolver.log"),
    ],
)
logger = logging.getLogger(__name__)

SQL_DIR = Path(__file__).parent.parent / "sql"


def seed_popular_names():
    """Create the popular names table and insert seed data."""
    logger.info("Seeding popular names from DLD Pulse reference data")
    run_sql_file(SQL_DIR / "005_popular_names.sql")
    logger.info("Popular names seeded")


def run_name_enrichment():
    """Run multi-strategy name resolution on all plots."""
    logger.info("Running name enrichment (EXACT_PLOT → PROJECT_MATCH → FUZZY)")
    run_sql_file(SQL_DIR / "006_name_enrichment.sql")
    logger.info("Name enrichment complete")


def import_from_json(file_path: str):
    """Import popular names from a DLD Pulse JSON export.

    Expected format:
    [
        {
            "dda_project_name": "DUBAI HILLS ESTATE",
            "popular_name": "Park Heights 1",
            "developer": "Emaar Properties",
            "community": "Park Heights",
            "asset_type": "APARTMENT",
            "status": "COMPLETED",
            "dld_project_id": "DLD-12345",
            "rera_number": "RERA-67890",
            "plot_numbers": ["123", "124", "125"]
        }
    ]
    """
    data = json.loads(Path(file_path).read_text())
    logger.info("Importing %d popular name records from %s", len(data), file_path)

    with get_conn() as conn:
        with conn.cursor() as cur:
            for record in data:
                cur.execute("""
                    INSERT INTO bronze.project_popular_names
                        (dda_project_name, popular_name, developer, source,
                         dld_project_id, rera_number, plot_numbers, community,
                         asset_type, status, confidence, match_method)
                    VALUES (%s, %s, %s, 'DLD_PULSE', %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (dda_project_name, popular_name) DO UPDATE SET
                        developer = EXCLUDED.developer,
                        dld_project_id = COALESCE(EXCLUDED.dld_project_id, bronze.project_popular_names.dld_project_id),
                        rera_number = COALESCE(EXCLUDED.rera_number, bronze.project_popular_names.rera_number),
                        plot_numbers = COALESCE(EXCLUDED.plot_numbers, bronze.project_popular_names.plot_numbers),
                        community = EXCLUDED.community,
                        asset_type = EXCLUDED.asset_type,
                        status = EXCLUDED.status,
                        confidence = EXCLUDED.confidence,
                        updated_at = now()
                """, (
                    record["dda_project_name"],
                    record["popular_name"],
                    record.get("developer"),
                    record.get("dld_project_id"),
                    record.get("rera_number"),
                    record.get("plot_numbers"),
                    record.get("community"),
                    record.get("asset_type"),
                    record.get("status"),
                    record.get("confidence", 1.0),
                    "EXACT" if record.get("plot_numbers") else "MANUAL",
                ))
            conn.commit()
    logger.info("Import complete")


def get_resolution_report() -> list[dict]:
    """Query name resolution quality per project."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    project_name,
                    total_plots,
                    resolved,
                    unresolved,
                    resolution_pct,
                    exact_matches,
                    project_matches,
                    fuzzy_matches,
                    avg_confidence,
                    distinct_popular_names,
                    popular_names_found
                FROM bronze.name_resolution_quality
                ORDER BY total_plots DESC
            """)
            columns = [desc[0] for desc in cur.description]
            return [dict(zip(columns, row)) for row in cur.fetchall()]


def search_plots(term: str, limit: int = 20) -> list[dict]:
    """Search plots by any name (official, popular, developer)."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT * FROM bronze.search_plots(%s, %s)
            """, (term, limit))
            columns = [desc[0] for desc in cur.description]
            return [dict(zip(columns, row)) for row in cur.fetchall()]


def get_stats() -> dict:
    """Get overall name resolution statistics."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    COUNT(*)                                                  AS total_plots,
                    COUNT(*) FILTER (WHERE popular_name IS NOT NULL)          AS resolved,
                    COUNT(*) FILTER (WHERE popular_name IS NULL AND project_name IS NOT NULL) AS unresolved,
                    COUNT(*) FILTER (WHERE name_match_method = 'EXACT_PLOT')  AS exact_plot,
                    COUNT(*) FILTER (WHERE name_match_method = 'PROJECT_MATCH') AS project_match,
                    COUNT(*) FILTER (WHERE name_match_method = 'FUZZY')       AS fuzzy,
                    COUNT(DISTINCT popular_name)                              AS distinct_popular,
                    COUNT(DISTINCT project_name)                              AS distinct_official,
                    ROUND(AVG(name_match_score) FILTER (WHERE name_match_score IS NOT NULL)::numeric, 2) AS avg_score
                FROM bronze.dda_plots
            """)
            columns = [desc[0] for desc in cur.description]
            return dict(zip(columns, cur.fetchone()))


def print_report(report: list[dict], stats: dict):
    """Print a human-readable name resolution report."""
    logger.info("")
    logger.info("=" * 70)
    logger.info("POPULAR NAME RESOLUTION REPORT")
    logger.info("=" * 70)
    logger.info("")
    logger.info("Overall:")
    logger.info("  Total plots:          %s", stats["total_plots"])
    logger.info("  Resolved:             %s", stats["resolved"])
    logger.info("  Unresolved:           %s", stats["unresolved"])
    logger.info("  Distinct popular:     %s", stats["distinct_popular"])
    logger.info("  Distinct official:    %s", stats["distinct_official"])
    logger.info("  Avg confidence:       %s", stats["avg_score"])
    logger.info("  Match breakdown:      EXACT=%s  PROJECT=%s  FUZZY=%s",
                stats["exact_plot"], stats["project_match"], stats["fuzzy"])
    logger.info("")

    for proj in report:
        logger.info("-" * 70)
        logger.info("PROJECT: %s", proj["project_name"])
        logger.info("  Plots: %s  Resolved: %s (%s%%)",
                     proj["total_plots"], proj["resolved"], proj["resolution_pct"])
        logger.info("  Match: EXACT=%s  PROJECT=%s  FUZZY=%s",
                     proj["exact_matches"], proj["project_matches"], proj["fuzzy_matches"])
        names = proj.get("popular_names_found") or []
        if names:
            logger.info("  Popular names: %s", ", ".join(names[:10]))
            if len(names) > 10:
                logger.info("    ... and %d more", len(names) - 10)


def run_full_resolution():
    """Run the complete name resolution pipeline."""
    seed_popular_names()
    run_name_enrichment()


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="Popular name resolution")
    parser.add_argument("--report", action="store_true",
                        help="Show resolution quality report")
    parser.add_argument("--search", type=str,
                        help="Search plots by name")
    parser.add_argument("--import-file", type=str,
                        help="Import popular names from JSON file")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")
    parser.add_argument("--skip-seed", action="store_true",
                        help="Skip seeding and enrichment, just report")
    args = parser.parse_args()

    if args.import_file:
        import_from_json(args.import_file)
        run_name_enrichment()
        return

    if args.search:
        results = search_plots(args.search)
        if args.json:
            print(json.dumps(results, indent=2, default=str))
        else:
            logger.info("Search results for '%s':", args.search)
            for r in results:
                logger.info("  %-15s  %-30s  %-30s  rank=%.2f",
                            r["plot_number"] or "?",
                            r["official_name"] or "?",
                            r["display_name"] or "?",
                            r["match_rank"])
        return

    if not args.skip_seed:
        run_full_resolution()

    if args.report or args.skip_seed:
        report = get_resolution_report()
        stats = get_stats()
        if args.json:
            print(json.dumps({"stats": stats, "projects": report}, indent=2, default=str))
        else:
            print_report(report, stats)


if __name__ == "__main__":
    main()
