#!/usr/bin/env python3
"""
ZEROAGENT Layer Orchestrator

Manages the 10-layer data architecture:
  Layer 1:  DDA GIS Plots          (existing — pipeline.ingest_plots)
  Layer 2:  DLD Transactions       (CSV load from Dubai Pulse)
  Layer 3:  View Assets + Blocking (pipeline.view_analysis)
  Layer 4:  Amenities              (DDA auto + Google Places + OSM)
  Layer 5:  Dubai 2040 + Infra     (manual + RTA)
  Layer 6:  Metro + Transit        (RTA open data)
  Layer 7:  Supply Pipeline        (computed from DDA)
  Layer 8:  Transformation Score   (computed from all layers)
  Layer 9:  Livability Index       (computed from amenities — future)
  Layer 10: Truth Layer            (DLD ↔ GIS cross-validation)

Usage:
    # Initialize all layer schemas + tables (first run)
    python -m pipeline.layers --init

    # Run all computation layers (after data is loaded)
    python -m pipeline.layers --compute

    # Load DLD transactions CSV
    python -m pipeline.layers --load-dld /path/to/Transactions.csv

    # Run specific layers only
    python -m pipeline.layers --layers 4,7,8

    # Show layer status
    python -m pipeline.layers --status
"""

import argparse
import csv
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
        logging.FileHandler("logs/layers.log"),
    ],
)
logger = logging.getLogger(__name__)

SQL_DIR = Path(__file__).parent.parent / "sql"

# Layer SQL files in execution order
LAYER_SQL = {
    "schemas":        SQL_DIR / "007_layer_schemas.sql",
    "dld_schema":     SQL_DIR / "008_dld_transactions.sql",
    "amenities":      SQL_DIR / "009_amenities.sql",
    "infra_transit":  SQL_DIR / "010_infrastructure_transit.sql",
    "gold_scores":    SQL_DIR / "011_gold_scores.sql",
    "frontend_rpc":   SQL_DIR / "012_frontend_rpc.sql",
}


def init_layer_schemas():
    """Create all layer schemas and tables (idempotent)."""
    logger.info("=" * 60)
    logger.info("INITIALIZING LAYER SCHEMAS")
    logger.info("=" * 60)

    for name, path in LAYER_SQL.items():
        logger.info("Running %s: %s", name, path.name)
        run_sql_file(path)
        logger.info("  Done: %s", name)

    logger.info("All layer schemas initialized")


def run_layer_computation(layer_numbers: list[int] | None = None):
    """Run computation layers. If layer_numbers is None, run all."""
    all_layers = layer_numbers or [1, 2, 3, 4, 5, 6, 7, 8, 10]

    logger.info("=" * 60)
    logger.info("COMPUTING LAYERS: %s", all_layers)
    logger.info("=" * 60)

    # Layer 1: Base columns (plot_status, display_name)
    if 1 in all_layers:
        logger.info("Layer 1: Deriving plot_status + display_name")
        run_sql_file(LAYER_SQL["schemas"])

    # Layer 2: DLD schema (table creation only, data loaded separately)
    if 2 in all_layers:
        logger.info("Layer 2: Ensuring DLD transactions schema exists")
        run_sql_file(LAYER_SQL["dld_schema"])

    # Layer 3: View blocking (handled by view_analysis module)
    if 3 in all_layers:
        from pipeline.view_analysis import run_full_analysis
        logger.info("Layer 3: Running view blocking analysis")
        run_full_analysis()

    # Layer 4: Amenities (DDA auto-populate + scoring)
    if 4 in all_layers:
        logger.info("Layer 4: Populating amenities + computing scores")
        run_sql_file(LAYER_SQL["amenities"])

    # Layers 5+6: Infrastructure + Transit
    if 5 in all_layers or 6 in all_layers:
        logger.info("Layers 5+6: Infrastructure + Transit seed data")
        run_sql_file(LAYER_SQL["infra_transit"])

    # Layers 7+8+10: Supply + Transformation + Truth
    if any(n in all_layers for n in [7, 8, 10]):
        logger.info("Layers 7+8+10: Supply pipeline + Transformation + Truth")
        run_sql_file(LAYER_SQL["gold_scores"])

    # Frontend RPC functions (always refresh)
    logger.info("Refreshing frontend RPC functions")
    run_sql_file(LAYER_SQL["frontend_rpc"])

    logger.info("Layer computation complete")


def load_dld_csv(csv_path: str, batch_size: int = 5000):
    """Load DLD transactions from CSV (Dubai Pulse export).

    Expected columns (standard Dubai Pulse Transactions.csv):
        transaction_id, instance_date, trans_group_en, trans_type_en,
        reg_type_en, area_name_en, project_name_en, property_type_en,
        property_sub_type_en, property_usage_en, rooms_en, has_parking,
        nearest_metro_en, nearest_mall_en, nearest_landmark_en,
        actual_worth, meter_sale_price, procedure_area,
        no_of_buyer_broker, no_of_seller_broker, master_project_en
    """
    csv_file = Path(csv_path)
    if not csv_file.exists():
        logger.error("CSV file not found: %s", csv_path)
        sys.exit(1)

    # Ensure schema exists
    run_sql_file(LAYER_SQL["dld_schema"])

    logger.info("Loading DLD transactions from: %s", csv_path)
    logger.info("File size: %.1f MB", csv_file.stat().st_size / (1024 * 1024))

    # Column mapping: CSV header → DB column
    col_map = {
        "transaction_id": "transaction_id",
        "instance_date": "instance_date",
        "trans_group_en": "trans_group_en",
        "trans_type_en": "trans_type_en",
        "reg_type_en": "reg_type_en",
        "area_name_en": "area_name_en",
        "project_name_en": "project_name_en",
        "property_type_en": "property_type_en",
        "property_sub_type_en": "property_sub_type_en",
        "property_usage_en": "property_usage_en",
        "rooms_en": "rooms_en",
        "has_parking": "has_parking",
        "nearest_metro_en": "nearest_metro_en",
        "nearest_mall_en": "nearest_mall_en",
        "nearest_landmark_en": "nearest_landmark_en",
        "actual_worth": "actual_worth",
        "meter_sale_price": "meter_sale_price",
        "procedure_area": "procedure_area",
        "no_of_buyer_broker": "no_of_buyer_broker",
        "no_of_seller_broker": "no_of_seller_broker",
        "master_project_en": "master_project_en",
    }

    total_rows = 0
    with get_conn() as conn:
        with conn.cursor() as cur:
            with open(csv_path, "r", encoding="utf-8", errors="replace") as f:
                reader = csv.DictReader(f)

                # Map CSV headers to our columns
                csv_cols = [h.strip().lower().replace(" ", "_") for h in reader.fieldnames or []]
                matched = {csv_h: col_map[csv_h] for csv_h in csv_cols if csv_h in col_map}
                db_cols = list(matched.values())

                logger.info("Matched %d/%d CSV columns to DB", len(matched), len(csv_cols))
                if len(matched) < 5:
                    logger.error("Too few columns matched. CSV headers: %s", csv_cols)
                    sys.exit(1)

                batch = []
                for row in reader:
                    values = []
                    raw = {}
                    for csv_h, db_col in matched.items():
                        val = row.get(csv_h, "").strip()
                        if val == "" or val.lower() == "null":
                            val = None
                        # Type conversions
                        if db_col in ("actual_worth", "meter_sale_price", "procedure_area"):
                            try:
                                val = float(val) if val else None
                            except (ValueError, TypeError):
                                val = None
                        if db_col in ("no_of_buyer_broker", "no_of_seller_broker"):
                            try:
                                val = int(val) if val else None
                            except (ValueError, TypeError):
                                val = None
                        if db_col == "has_parking":
                            val = val.lower() in ("true", "1", "yes") if val else None
                        values.append(val)
                        raw[csv_h] = row.get(csv_h)

                    values.append(json.dumps(raw))  # raw_data
                    batch.append(values)

                    if len(batch) >= batch_size:
                        _insert_batch(cur, db_cols, batch)
                        total_rows += len(batch)
                        if total_rows % 50000 == 0:
                            logger.info("  Loaded %d rows...", total_rows)
                        batch = []

                # Final batch
                if batch:
                    _insert_batch(cur, db_cols, batch)
                    total_rows += len(batch)

            conn.commit()

    logger.info("DLD load complete: %d rows", total_rows)

    # Refresh materialized view
    logger.info("Refreshing DLD project summary materialized view")
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("REFRESH MATERIALIZED VIEW bronze.dld_project_summary")
        conn.commit()

    logger.info("DLD summary refreshed")
    return total_rows


def _insert_batch(cur, db_cols: list[str], batch: list[list]):
    """Insert a batch of rows into dld_transactions."""
    cols_str = ", ".join(db_cols + ["raw_data"])
    placeholders = ", ".join(["%s"] * (len(db_cols) + 1))
    sql = f"INSERT INTO bronze.dld_transactions ({cols_str}) VALUES ({placeholders})"
    cur.executemany(sql, batch)


def get_layer_status() -> dict:
    """Check which layers have data and their row counts."""
    status = {}
    checks = [
        ("Layer 1: DDA Plots", "SELECT COUNT(*) FROM bronze.dda_plots"),
        ("Layer 2: DLD Transactions", "SELECT COUNT(*) FROM bronze.dld_transactions"),
        ("Layer 3: Visual Assets", "SELECT COUNT(*) FROM bronze.visual_assets"),
        ("Layer 3: View Threats", "SELECT COUNT(*) FROM bronze.dda_plots WHERE view_threat_level IS NOT NULL AND view_threat_level != 'NONE'"),
        ("Layer 4: Amenities", "SELECT COUNT(*) FROM layers.amenities"),
        ("Layer 4: Amenity Scores", "SELECT COUNT(*) FROM gold.amenity_scores"),
        ("Layer 5: Infrastructure", "SELECT COUNT(*) FROM layers.infrastructure"),
        ("Layer 6: Transit", "SELECT COUNT(*) FROM layers.transit"),
        ("Layer 7: Supply Pipeline", "SELECT COUNT(*) FROM gold.supply_pipeline"),
        ("Layer 8: Transformation", "SELECT COUNT(*) FROM gold.transformation_score"),
        ("Layer 10: Truth Validation", "SELECT COUNT(*) FROM gold.truth_validation"),
        ("Popular Names", "SELECT COUNT(*) FROM bronze.project_popular_names"),
        ("Name Resolved Plots", "SELECT COUNT(*) FROM bronze.dda_plots WHERE popular_name IS NOT NULL"),
    ]

    with get_conn() as conn:
        with conn.cursor() as cur:
            for label, query in checks:
                try:
                    cur.execute(query)
                    count = cur.fetchone()[0]
                    status[label] = count
                except Exception:
                    status[label] = "NOT INITIALIZED"
                    conn.rollback()

    return status


def print_status(status: dict):
    """Print a formatted layer status report."""
    logger.info("")
    logger.info("=" * 60)
    logger.info("ZEROAGENT LAYER STATUS")
    logger.info("=" * 60)
    for label, count in status.items():
        icon = "x" if count == "NOT INITIALIZED" else ("." if count == 0 else "+")
        logger.info("  [%s] %-35s %s", icon, label, count)
    logger.info("=" * 60)


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="ZEROAGENT Layer Orchestrator")
    parser.add_argument("--init", action="store_true",
                        help="Initialize all layer schemas and tables")
    parser.add_argument("--compute", action="store_true",
                        help="Run all computation layers")
    parser.add_argument("--layers", type=str,
                        help="Run specific layers (comma-separated, e.g. '4,7,8')")
    parser.add_argument("--load-dld", type=str,
                        help="Load DLD transactions from CSV file")
    parser.add_argument("--status", action="store_true",
                        help="Show layer status")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")
    args = parser.parse_args()

    if args.init:
        init_layer_schemas()

    if args.load_dld:
        load_dld_csv(args.load_dld)

    if args.compute:
        run_layer_computation()

    if args.layers:
        nums = [int(n.strip()) for n in args.layers.split(",")]
        run_layer_computation(nums)

    if args.status:
        status = get_layer_status()
        if args.json:
            print(json.dumps(status, indent=2, default=str))
        else:
            print_status(status)

    # Default: show status if no action specified
    if not any([args.init, args.compute, args.layers, args.load_dld, args.status]):
        parser.print_help()


if __name__ == "__main__":
    main()
