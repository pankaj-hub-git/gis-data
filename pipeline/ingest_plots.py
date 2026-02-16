#!/usr/bin/env python3
"""
Step 3 + 4: Ingest plots from DDA BASIC_LAND_BASE/MapServer/2.

Usage:
    # MVP: specific projects
    python -m pipeline.ingest_plots --projects "DUBAI HILLS" "BUSINESS BAY"

    # Full Dubai scrape using spatial tiles
    python -m pipeline.ingest_plots --full

    # Resume an interrupted full scrape
    python -m pipeline.ingest_plots --full --resume
"""

import argparse
import json
import logging
import sys
import time
from pathlib import Path

from pipeline.config import DUBAI_BBOX, GRID_DIVISIONS, SERVICES
from pipeline.db import (
    get_conn,
    init_schema,
    log_ingestion_end,
    log_ingestion_progress,
    log_ingestion_start,
    upsert_plot,
)
from pipeline.field_map import PLOT_FIELD_MAP, auto_match_fields
from pipeline.http_client import fetch_geojson, fetch_json

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/ingest_plots.log"),
    ],
)
logger = logging.getLogger(__name__)

SVC = SERVICES["basic_land_base"]
QUERY_URL = f"{SVC['url']}/{SVC['layers']['plot']}/query"
MAX_RECORDS = SVC["max_record_count"]
PROGRESS_FILE = Path("logs/tile_progress.json")


def detect_field_map() -> dict[str, str]:
    """Fetch layer metadata and build the field map dynamically."""
    layer_url = f"{SVC['url']}/{SVC['layers']['plot']}"
    logger.info("Detecting fields from %s", layer_url)
    meta = fetch_json(layer_url)
    actual_fields = [f["name"] for f in meta.get("fields", [])]
    logger.info("API fields found: %s", actual_fields)
    matched = auto_match_fields(actual_fields, PLOT_FIELD_MAP)
    logger.info("Matched field map: %s", matched)

    # Warn about unmatched DB columns
    for db_col in PLOT_FIELD_MAP:
        if db_col not in matched:
            logger.warning("No API field matched for DB column: %s", db_col)

    return matched


def query_paginated(where: str, geometry_filter: dict | None = None) -> list[dict]:
    """Query plots with pagination, returning all features."""
    all_features = []
    offset = 0

    while True:
        params = {
            "where": where,
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "resultOffset": str(offset),
            "resultRecordCount": str(MAX_RECORDS),
            "orderByFields": "OBJECTID ASC",
        }

        if geometry_filter:
            params["geometry"] = json.dumps(geometry_filter)
            params["geometryType"] = "esriGeometryEnvelope"
            params["inSR"] = "4326"
            params["spatialRel"] = "esriSpatialRelIntersects"

        try:
            data = fetch_geojson(QUERY_URL, params)
        except Exception as exc:
            logger.error("Query failed (offset=%d, where=%s): %s", offset, where, exc)
            break

        features = data.get("features", [])
        if not features:
            break

        all_features.extend(features)
        logger.info("  Fetched %d features (total so far: %d, offset: %d)", len(features), len(all_features), offset)

        # ArcGIS indicates more results if we got exactly max records
        if len(features) < MAX_RECORDS:
            break

        offset += MAX_RECORDS

    return all_features


def ingest_features(features: list[dict], field_map: dict[str, str]) -> int:
    """Upsert a list of features into the database. Returns count upserted."""
    if not features:
        return 0

    upserted = 0
    with get_conn() as conn:
        with conn.cursor() as cur:
            for feat in features:
                try:
                    upsert_plot(cur, feat, field_map)
                    upserted += 1
                except Exception as exc:
                    oid = feat.get("properties", {}).get("OBJECTID", "?")
                    logger.error("Failed to upsert plot OBJECTID=%s: %s", oid, exc)

    return upserted


def ingest_by_project(project_names: list[str]):
    """Step 3: Ingest plots for specific projects."""
    init_schema()
    field_map = detect_field_map()

    total_fetched = 0
    total_upserted = 0

    for name in project_names:
        log_id = log_ingestion_start("dda_plots")
        where = f"PROJECT_NAME LIKE '%{name}%'"
        logger.info("=== Ingesting plots for: %s ===", name)

        try:
            features = query_paginated(where)
            logger.info("Fetched %d features for %s", len(features), name)
            total_fetched += len(features)

            upserted = ingest_features(features, field_map)
            total_upserted += upserted
            logger.info("Upserted %d plots for %s", upserted, name)

            log_ingestion_progress(log_id, len(features), upserted, 1)
            log_ingestion_end(log_id, "completed")

        except Exception as exc:
            logger.error("Failed to ingest %s: %s", name, exc)
            log_ingestion_end(log_id, "failed", str(exc))

    logger.info("=== Project ingestion complete: %d fetched, %d upserted ===", total_fetched, total_upserted)


def generate_tiles() -> list[dict]:
    """Generate a grid of bounding box tiles covering Dubai."""
    bbox = DUBAI_BBOX
    x_step = (bbox["xmax"] - bbox["xmin"]) / GRID_DIVISIONS
    y_step = (bbox["ymax"] - bbox["ymin"]) / GRID_DIVISIONS

    tiles = []
    for xi in range(GRID_DIVISIONS):
        for yi in range(GRID_DIVISIONS):
            tile = {
                "xmin": bbox["xmin"] + xi * x_step,
                "ymin": bbox["ymin"] + yi * y_step,
                "xmax": bbox["xmin"] + (xi + 1) * x_step,
                "ymax": bbox["ymin"] + (yi + 1) * y_step,
                "index": xi * GRID_DIVISIONS + yi,
            }
            tiles.append(tile)

    return tiles


def load_progress() -> set[int]:
    """Load completed tile indices from progress file."""
    if PROGRESS_FILE.exists():
        data = json.loads(PROGRESS_FILE.read_text())
        return set(data.get("completed_tiles", []))
    return set()


def save_progress(completed: set[int]):
    """Save completed tile indices to progress file."""
    PROGRESS_FILE.parent.mkdir(exist_ok=True)
    PROGRESS_FILE.write_text(json.dumps({
        "completed_tiles": sorted(completed),
        "total_tiles": GRID_DIVISIONS * GRID_DIVISIONS,
    }))


def ingest_full_dubai(resume: bool = False):
    """Step 4: Full spatial tile scrape of all Dubai plots."""
    init_schema()
    field_map = detect_field_map()

    tiles = generate_tiles()
    total_tiles = len(tiles)
    completed_tiles = load_progress() if resume else set()

    if resume and completed_tiles:
        logger.info("Resuming: %d/%d tiles already completed", len(completed_tiles), total_tiles)

    log_id = log_ingestion_start("dda_plots", tiles_total=total_tiles)
    total_fetched = 0
    total_upserted = 0

    try:
        for tile in tiles:
            idx = tile["index"]
            if idx in completed_tiles:
                continue

            envelope = {
                "xmin": tile["xmin"],
                "ymin": tile["ymin"],
                "xmax": tile["xmax"],
                "ymax": tile["ymax"],
                "spatialReference": {"wkid": 4326},
            }

            logger.info(
                "Tile %d/%d [%.4f,%.4f → %.4f,%.4f]",
                idx + 1, total_tiles,
                tile["xmin"], tile["ymin"], tile["xmax"], tile["ymax"],
            )

            features = query_paginated("1=1", geometry_filter=envelope)

            if features:
                upserted = ingest_features(features, field_map)
                total_fetched += len(features)
                total_upserted += upserted
                logger.info("  → %d fetched, %d upserted", len(features), upserted)
            else:
                logger.info("  → 0 features (empty tile)")

            completed_tiles.add(idx)
            save_progress(completed_tiles)
            log_ingestion_progress(log_id, total_fetched, total_upserted, len(completed_tiles))

        log_ingestion_end(log_id, "completed")
        logger.info("=== Full scrape complete: %d fetched, %d upserted across %d tiles ===",
                     total_fetched, total_upserted, total_tiles)

    except KeyboardInterrupt:
        logger.info("Interrupted. Progress saved (%d/%d tiles). Use --resume to continue.",
                     len(completed_tiles), total_tiles)
        log_ingestion_end(log_id, "interrupted")
        save_progress(completed_tiles)
        sys.exit(1)

    except Exception as exc:
        logger.error("Fatal error during full scrape: %s", exc)
        log_ingestion_end(log_id, "failed", str(exc))
        save_progress(completed_tiles)
        raise


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="Ingest DDA plot data")
    parser.add_argument("--projects", nargs="+", help="Project names to ingest (MVP mode)")
    parser.add_argument("--full", action="store_true", help="Full Dubai spatial tile scrape")
    parser.add_argument("--resume", action="store_true", help="Resume interrupted full scrape")
    args = parser.parse_args()

    if args.projects:
        ingest_by_project(args.projects)
    elif args.full:
        ingest_full_dubai(resume=args.resume)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
