#!/usr/bin/env python3
"""
Step 6: Run SQL enrichment on ingested data.

Usage:
    python -m pipeline.enrich
"""

import logging
import sys
from pathlib import Path

from pipeline.db import get_conn, run_sql_file

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/enrich.log"),
    ],
)
logger = logging.getLogger(__name__)


def main():
    Path("logs").mkdir(exist_ok=True)

    # Step 1: Base enrichment (floor counts, land use, centroids, units, buildable flags)
    sql_path = Path(__file__).parent.parent / "sql" / "002_enrichment.sql"
    logger.info("Running enrichment SQL: %s", sql_path)
    run_sql_file(sql_path)
    logger.info("Enrichment complete")

    # Step 2: Popular name resolution (DLD Pulse → DDA name matching)
    from pipeline.name_resolver import run_full_resolution
    logger.info("Running popular name resolution")
    run_full_resolution()
    logger.info("Popular name resolution complete")

    # Step 3: View blocking analysis (visual assets + threat computation)
    from pipeline.view_analysis import run_full_analysis
    logger.info("Running view blocking analysis")
    run_full_analysis()
    logger.info("View blocking analysis complete")

    # Print summary stats
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots")
            total = cur.fetchone()[0]
            logger.info("Total plots: %d", total)

            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE floor_count IS NOT NULL")
            enriched = cur.fetchone()[0]
            logger.info("Plots with floor count: %d", enriched)

            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE is_buildable = TRUE")
            buildable = cur.fetchone()[0]
            logger.info("Buildable plots: %d", buildable)

            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE site_plan_active = TRUE")
            active = cur.fetchone()[0]
            logger.info("Active site plans: %d", active)

            # View blocking stats
            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE is_view_blocker = TRUE")
            blockers = cur.fetchone()[0]
            logger.info("View blocker plots: %d", blockers)

            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE view_threat_level IN ('CRITICAL','HIGH')")
            high_threats = cur.fetchone()[0]
            logger.info("CRITICAL+HIGH view threats: %d", high_threats)

            cur.execute("SELECT COUNT(*) FROM bronze.dda_plots WHERE popular_name IS NOT NULL")
            named = cur.fetchone()[0]
            logger.info("Plots with popular name: %d", named)

            cur.execute("""
                SELECT project_name, COUNT(*), SUM(estimated_units)
                FROM bronze.dda_plots
                WHERE project_name IS NOT NULL
                GROUP BY project_name
                ORDER BY COUNT(*) DESC
                LIMIT 10
            """)
            logger.info("Top 10 projects by plot count:")
            for row in cur.fetchall():
                logger.info("  %-40s  plots=%d  est_units=%s", row[0], row[1], row[2])


if __name__ == "__main__":
    main()
