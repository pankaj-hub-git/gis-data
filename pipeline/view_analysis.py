#!/usr/bin/env python3
"""
View blocking analysis for Dubai plots.

Runs the visual-asset seeding and view-corridor analysis SQL,
then prints a project-level threat report.

Usage:
    # Run full view analysis (seed assets + compute threats)
    python -m pipeline.view_analysis

    # Show report only (skip re-computation)
    python -m pipeline.view_analysis --report-only

    # Output as JSON for frontend/Mapbox consumption
    python -m pipeline.view_analysis --json
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
        logging.FileHandler("logs/view_analysis.log"),
    ],
)
logger = logging.getLogger(__name__)

SQL_DIR = Path(__file__).parent.parent / "sql"


def seed_visual_assets():
    """Create visual_assets table and insert landmark data."""
    logger.info("Seeding visual assets (Burj Khalifa, Burj Park, Water Canal, etc.)")
    run_sql_file(SQL_DIR / "003_visual_assets.sql")
    logger.info("Visual assets seeded")


def run_view_blocking_analysis():
    """Run the view corridor and threat analysis SQL."""
    logger.info("Running view blocking analysis (distance, bearing, threat levels, blocker detection)")
    run_sql_file(SQL_DIR / "004_view_blocking.sql")
    logger.info("View blocking analysis complete")


def get_project_threat_report() -> list[dict]:
    """Query the project_view_threat view for a summary report."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    project_name,
                    total_plots,
                    plots_that_block_views,
                    total_plots_affected,
                    critical_threats,
                    high_threats,
                    medium_threats,
                    low_threats,
                    avg_distance_to_burj_m,
                    closest_plot_to_burj_m,
                    plots_with_blockers_ahead,
                    project_threat_statement
                FROM bronze.project_view_threat
                ORDER BY critical_threats DESC, high_threats DESC
            """)
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchall()
            return [dict(zip(columns, row)) for row in rows]


def get_threat_stats() -> dict:
    """Get overall threat statistics."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    COUNT(*)                                                    AS total_plots,
                    COUNT(*) FILTER (WHERE view_threat_level = 'CRITICAL')      AS critical,
                    COUNT(*) FILTER (WHERE view_threat_level = 'HIGH')          AS high,
                    COUNT(*) FILTER (WHERE view_threat_level = 'MEDIUM')        AS medium,
                    COUNT(*) FILTER (WHERE view_threat_level = 'LOW')           AS low,
                    COUNT(*) FILTER (WHERE view_threat_level = 'NONE' OR view_threat_level IS NULL) AS none,
                    COUNT(*) FILTER (WHERE is_view_blocker)                     AS total_blockers,
                    COALESCE(SUM(blocks_burj_view_for), 0)                      AS total_blocked_plots
                FROM bronze.dda_plots
                WHERE burj_khalifa_distance_m IS NOT NULL
            """)
            row = cur.fetchone()
            columns = [desc[0] for desc in cur.description]
            return dict(zip(columns, row))


def get_focus_project_details(project_names: list[str]) -> list[dict]:
    """Get detailed view threat info for specific projects (Business Bay, Dubai Hills)."""
    results = []
    with get_conn() as conn:
        with conn.cursor() as cur:
            for name in project_names:
                cur.execute("""
                    SELECT
                        plot_number,
                        floor_count,
                        max_height,
                        burj_distance_m,
                        view_threat_level,
                        is_view_blocker,
                        blocks_burj_view_for,
                        view_warning_message
                    FROM bronze.plot_view_detail
                    WHERE project_name LIKE %s
                      AND (view_threat_level != 'NONE' OR is_view_blocker = TRUE)
                    ORDER BY
                        CASE view_threat_level
                            WHEN 'CRITICAL' THEN 1
                            WHEN 'HIGH' THEN 2
                            WHEN 'MEDIUM' THEN 3
                            WHEN 'LOW' THEN 4
                            ELSE 5
                        END,
                        burj_distance_m
                """, (f"%{name}%",))
                columns = [desc[0] for desc in cur.description]
                plots = [dict(zip(columns, row)) for row in cur.fetchall()]
                results.append({
                    "project": name,
                    "threat_plots": plots,
                    "count": len(plots),
                })
    return results


def print_report(projects: list[dict], stats: dict):
    """Print a human-readable threat report."""
    logger.info("")
    logger.info("=" * 70)
    logger.info("BURJ KHALIFA VIEW BLOCKING THREAT REPORT")
    logger.info("=" * 70)
    logger.info("")
    logger.info("Overall stats:")
    logger.info("  Total plots analyzed:     %d", stats["total_plots"])
    logger.info("  CRITICAL threat plots:    %d", stats["critical"])
    logger.info("  HIGH threat plots:        %d", stats["high"])
    logger.info("  MEDIUM threat plots:      %d", stats["medium"])
    logger.info("  LOW threat plots:         %d", stats["low"])
    logger.info("  View blocker plots:       %d", stats["total_blockers"])
    logger.info("  Total plots affected:     %d", stats["total_blocked_plots"])
    logger.info("")

    for proj in projects:
        logger.info("-" * 70)
        logger.info("PROJECT: %s", proj["project_name"])
        logger.info("  %s", proj["project_threat_statement"])
        logger.info("  Total plots:            %s", proj["total_plots"])
        logger.info("  View blockers:          %s", proj["plots_that_block_views"])
        logger.info("  Plots affected:         %s", proj["total_plots_affected"])
        logger.info("  Avg distance to Burj:   %sm", proj["avg_distance_to_burj_m"])
        logger.info("  Closest plot to Burj:   %sm", proj["closest_plot_to_burj_m"])
        logger.info("  Threat breakdown:  CRITICAL=%s  HIGH=%s  MEDIUM=%s  LOW=%s",
                     proj["critical_threats"], proj["high_threats"],
                     proj["medium_threats"], proj["low_threats"])


def run_full_analysis():
    """Run the complete view analysis pipeline."""
    seed_visual_assets()
    run_view_blocking_analysis()


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="View blocking analysis")
    parser.add_argument("--report-only", action="store_true",
                        help="Show report without re-running analysis")
    parser.add_argument("--json", action="store_true",
                        help="Output JSON report for frontend/Mapbox")
    args = parser.parse_args()

    if not args.report_only:
        run_full_analysis()

    # Generate report
    projects = get_project_threat_report()
    stats = get_threat_stats()

    if args.json:
        focus = get_focus_project_details(["DUBAI HILLS", "BUSINESS BAY"])
        report = {
            "stats": stats,
            "projects": projects,
            "focus_projects": focus,
        }
        print(json.dumps(report, indent=2, default=str))
        Path("logs/view_threat_report.json").write_text(
            json.dumps(report, indent=2, default=str)
        )
    else:
        print_report(projects, stats)


if __name__ == "__main__":
    main()
