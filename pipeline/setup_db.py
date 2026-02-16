#!/usr/bin/env python3
"""
Initialize the PostGIS database schema.

Usage:
    python -m pipeline.setup_db
"""

import logging
import sys

from pipeline.db import get_conn, init_schema

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


def main():
    logger.info("Initializing database schema...")
    init_schema()

    # Verify
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT PostGIS_Version()")
            version = cur.fetchone()[0]
            logger.info("PostGIS version: %s", version)

            cur.execute("""
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'bronze'
                ORDER BY table_name
            """)
            tables = [row[0] for row in cur.fetchall()]
            logger.info("Bronze tables created: %s", tables)

    logger.info("Database setup complete")


if __name__ == "__main__":
    main()
