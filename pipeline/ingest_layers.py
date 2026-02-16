#!/usr/bin/env python3
"""
Step 5: Ingest project boundaries, construction status, and explore other services.

Usage:
    # Ingest project boundaries
    python -m pipeline.ingest_layers --layer projects

    # Ingest construction status
    python -m pipeline.ingest_layers --layer construction

    # Ingest all auxiliary layers
    python -m pipeline.ingest_layers --all

    # Explore additional service folders
    python -m pipeline.ingest_layers --explore
"""

import argparse
import json
import logging
import sys
from pathlib import Path

from pipeline.config import BASE_URL, EXTRA_FOLDERS, SERVICES
from pipeline.db import (
    get_conn,
    init_schema,
    log_ingestion_end,
    log_ingestion_progress,
    log_ingestion_start,
    upsert_construction,
    upsert_project,
)
from pipeline.field_map import (
    CONSTRUCTION_FIELD_MAP,
    PROJECT_FIELD_MAP,
    auto_match_fields,
)
from pipeline.http_client import fetch_geojson, fetch_json

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/ingest_layers.log"),
    ],
)
logger = logging.getLogger(__name__)


def query_all_features(base_url: str, layer_id: int, max_records: int) -> list[dict]:
    """Paginated query for all features in a layer."""
    query_url = f"{base_url}/{layer_id}/query"
    all_features = []
    offset = 0

    while True:
        params = {
            "where": "1=1",
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "resultOffset": str(offset),
            "resultRecordCount": str(max_records),
            "orderByFields": "OBJECTID ASC",
        }

        try:
            data = fetch_geojson(query_url, params)
        except Exception as exc:
            logger.error("Query failed (offset=%d): %s", offset, exc)
            break

        features = data.get("features", [])
        if not features:
            break

        all_features.extend(features)
        logger.info("  Fetched %d (total: %d)", len(features), len(all_features))

        if len(features) < max_records:
            break
        offset += max_records

    return all_features


def detect_field_map_for_layer(base_url: str, layer_id: int, expected_map: dict) -> dict[str, str]:
    """Fetch layer metadata and build matched field map."""
    url = f"{base_url}/{layer_id}"
    meta = fetch_json(url)
    actual_fields = [f["name"] for f in meta.get("fields", [])]
    logger.info("API fields: %s", actual_fields)
    matched = auto_match_fields(actual_fields, expected_map)
    logger.info("Matched: %s", matched)
    return matched


def ingest_projects():
    """Ingest project boundaries from BASIC_LAND_BASE layer 0."""
    svc = SERVICES["basic_land_base"]
    layer_id = svc["layers"]["project_limit"]
    logger.info("=== Ingesting project boundaries ===")

    field_map = detect_field_map_for_layer(svc["url"], layer_id, PROJECT_FIELD_MAP)
    log_id = log_ingestion_start("dda_projects")

    try:
        features = query_all_features(svc["url"], layer_id, svc["max_record_count"])
        logger.info("Fetched %d project boundaries", len(features))

        upserted = 0
        with get_conn() as conn:
            with conn.cursor() as cur:
                for feat in features:
                    try:
                        upsert_project(cur, feat, field_map)
                        upserted += 1
                    except Exception as exc:
                        oid = feat.get("properties", {}).get("OBJECTID", "?")
                        logger.error("Failed to upsert project OBJECTID=%s: %s", oid, exc)

        log_ingestion_progress(log_id, len(features), upserted, 1)
        log_ingestion_end(log_id, "completed")
        logger.info("Upserted %d project boundaries", upserted)

    except Exception as exc:
        logger.error("Project ingestion failed: %s", exc)
        log_ingestion_end(log_id, "failed", str(exc))
        raise


def ingest_construction_status():
    """Ingest construction status from ZonesControl layer 3."""
    svc = SERVICES["zones_control"]
    layer_id = svc["layers"]["construction_status"]
    logger.info("=== Ingesting construction status ===")

    field_map = detect_field_map_for_layer(svc["url"], layer_id, CONSTRUCTION_FIELD_MAP)
    log_id = log_ingestion_start("dda_construction_status")

    try:
        features = query_all_features(svc["url"], layer_id, svc["max_record_count"])
        logger.info("Fetched %d construction status records", len(features))

        upserted = 0
        with get_conn() as conn:
            with conn.cursor() as cur:
                for feat in features:
                    try:
                        upsert_construction(cur, feat, field_map)
                        upserted += 1
                    except Exception as exc:
                        oid = feat.get("properties", {}).get("OBJECTID", "?")
                        logger.error("Failed to upsert construction OBJECTID=%s: %s", oid, exc)

        log_ingestion_progress(log_id, len(features), upserted, 1)
        log_ingestion_end(log_id, "completed")
        logger.info("Upserted %d construction status records", upserted)

    except Exception as exc:
        logger.error("Construction status ingestion failed: %s", exc)
        log_ingestion_end(log_id, "failed", str(exc))
        raise


def explore_extra_services():
    """Explore additional service folders and report what layers are available."""
    logger.info("=== Exploring additional service folders ===")
    report = {}

    for folder in EXTRA_FOLDERS:
        url = f"{BASE_URL}/{folder}"
        logger.info("--- %s ---", folder)

        try:
            data = fetch_json(url)
        except Exception as exc:
            logger.warning("Could not explore %s: %s", folder, exc)
            continue

        services = data.get("services", [])
        folder_services = []

        for svc in services:
            svc_name = svc.get("name")
            svc_type = svc.get("type")
            logger.info("  Service: %s (%s)", svc_name, svc_type)

            # Try to get layer listing for MapServer services
            if svc_type == "MapServer":
                svc_url = f"{BASE_URL}/{svc_name}/{svc_type}"
                try:
                    svc_meta = fetch_json(svc_url)
                    layers = svc_meta.get("layers", [])
                    layer_info = []
                    for lyr in layers:
                        logger.info("    Layer %d: %s", lyr.get("id", -1), lyr.get("name", "?"))
                        layer_info.append({
                            "id": lyr.get("id"),
                            "name": lyr.get("name"),
                        })
                    folder_services.append({
                        "name": svc_name,
                        "type": svc_type,
                        "layers": layer_info,
                    })
                except Exception as exc:
                    logger.warning("    Could not fetch layers: %s", exc)
                    folder_services.append({"name": svc_name, "type": svc_type, "layers": []})
            else:
                folder_services.append({"name": svc_name, "type": svc_type})

        report[folder] = folder_services

    # Write exploration report
    report_path = Path("logs/extra_services_report.json")
    report_path.write_text(json.dumps(report, indent=2))
    logger.info("Extra services report written to %s", report_path)


def main():
    Path("logs").mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(description="Ingest auxiliary DDA GIS layers")
    parser.add_argument("--layer", choices=["projects", "construction"], help="Specific layer to ingest")
    parser.add_argument("--all", action="store_true", help="Ingest all auxiliary layers")
    parser.add_argument("--explore", action="store_true", help="Explore extra service folders")
    args = parser.parse_args()

    init_schema()

    if args.layer == "projects" or args.all:
        ingest_projects()
    if args.layer == "construction" or args.all:
        ingest_construction_status()
    if args.explore:
        explore_extra_services()
    if not args.layer and not args.all and not args.explore:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
