#!/usr/bin/env python3
"""
Step 1: Discovery — fetch field schemas and sample data from DDA GIS endpoints.

Run:
    python -m pipeline.discover

This will:
  1. Fetch layer metadata (fields, geometry type, etc.) for key layers
  2. Query 5 sample plots and print their field names + values
  3. Explore additional service folders for discoverable layers
  4. Write a summary to logs/discovery_report.json
"""

import json
import logging
import sys
from pathlib import Path

from pipeline.config import BASE_URL, EXTRA_FOLDERS, SERVICES
from pipeline.http_client import fetch_geojson, fetch_json

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("logs/discovery.log", mode="w"),
    ],
)
logger = logging.getLogger(__name__)

REPORT: dict = {}


def discover_layer(service_key: str, layer_name: str) -> dict | None:
    """Fetch and print the field schema for a single layer."""
    svc = SERVICES[service_key]
    layer_id = svc["layers"][layer_name]
    url = f"{svc['url']}/{layer_id}"

    logger.info("--- Discovering %s / %s (layer %d) ---", service_key, layer_name, layer_id)

    try:
        meta = fetch_json(url)
    except Exception as exc:
        logger.error("Failed to fetch layer metadata: %s", exc)
        return None

    info = {
        "name": meta.get("name"),
        "type": meta.get("type"),
        "geometryType": meta.get("geometryType"),
        "maxRecordCount": meta.get("maxRecordCount"),
        "spatialReference": meta.get("extent", {}).get("spatialReference", {}),
        "capabilities": meta.get("capabilities"),
        "supportsAdvancedQueries": meta.get("supportsAdvancedQueries"),
        "fields": [],
    }

    logger.info("  Name: %s", info["name"])
    logger.info("  Geometry: %s", info["geometryType"])
    logger.info("  Max records: %s", info["maxRecordCount"])
    logger.info("  Capabilities: %s", info["capabilities"])
    logger.info("  Fields:")

    for field in meta.get("fields", []):
        f = {
            "name": field["name"],
            "type": field["type"],
            "alias": field.get("alias", ""),
            "length": field.get("length"),
        }
        info["fields"].append(f)
        logger.info("    %-35s %-25s alias=%-35s len=%s", f["name"], f["type"], f["alias"], f["length"])

    return info


def sample_plots(n: int = 5) -> list[dict] | None:
    """Query n sample plots and print their properties."""
    svc = SERVICES["basic_land_base"]
    url = f"{svc['url']}/{svc['layers']['plot']}/query"
    params = {
        "where": "1=1",
        "outFields": "*",
        "returnGeometry": "true",
        "outSR": "4326",
        "resultRecordCount": str(n),
    }

    logger.info("--- Fetching %d sample plots ---", n)

    try:
        data = fetch_geojson(url, params)
    except Exception as exc:
        logger.error("Failed to fetch sample plots: %s", exc)
        return None

    features = data.get("features", [])
    logger.info("Received %d features", len(features))

    samples = []
    for i, feat in enumerate(features):
        props = feat.get("properties", {})
        geom = feat.get("geometry", {})
        logger.info("\n  === Sample Plot %d ===", i + 1)
        for key, val in props.items():
            logger.info("    %-35s = %s", key, val)
        logger.info("    geometry type: %s", geom.get("type"))
        coords = geom.get("coordinates", [])
        if coords:
            ring = coords[0] if geom.get("type") == "Polygon" else coords[0][0] if coords else []
            logger.info("    vertices: %d", len(ring) if ring else 0)
            if ring:
                logger.info("    first coord: %s", ring[0])
        samples.append({"properties": props, "geometry_type": geom.get("type")})

    return samples


def explore_folder(folder: str) -> list[dict]:
    """List services in an ArcGIS Server folder."""
    url = f"{BASE_URL}/{folder}"
    logger.info("--- Exploring folder: %s ---", folder)

    try:
        data = fetch_json(url)
    except Exception as exc:
        logger.warning("Could not explore folder %s: %s", folder, exc)
        return []

    services = data.get("services", [])
    found = []
    for svc in services:
        info = {"name": svc.get("name"), "type": svc.get("type")}
        logger.info("  %s (%s)", info["name"], info["type"])
        found.append(info)

    if not services:
        logger.info("  (no services found)")

    return found


def count_total_records() -> int | None:
    """Get total plot count using returnCountOnly."""
    svc = SERVICES["basic_land_base"]
    url = f"{svc['url']}/{svc['layers']['plot']}/query"
    params = {
        "where": "1=1",
        "returnCountOnly": "true",
    }

    logger.info("--- Counting total plots ---")
    try:
        data = fetch_json(url, params)
        count = data.get("count")
        logger.info("  Total plots: %s", count)
        return count
    except Exception as exc:
        logger.error("Failed to count plots: %s", exc)
        return None


def main():
    Path("logs").mkdir(exist_ok=True)
    logger.info("=" * 60)
    logger.info("DDA GIS DISCOVERY")
    logger.info("=" * 60)

    # 1. Layer schemas
    layers_info = {}
    for svc_key, layer_name in [
        ("basic_land_base", "plot"),
        ("basic_land_base", "project_limit"),
        ("zones_control", "construction_status"),
    ]:
        info = discover_layer(svc_key, layer_name)
        if info:
            layers_info[f"{svc_key}/{layer_name}"] = info

    # 2. Sample plots
    samples = sample_plots(5)

    # 3. Total count
    total = count_total_records()

    # 4. Explore extra folders
    extra = {}
    for folder in EXTRA_FOLDERS:
        found = explore_folder(folder)
        if found:
            extra[folder] = found

    # 5. Write report
    REPORT["layers"] = layers_info
    REPORT["sample_field_names"] = (
        list(samples[0]["properties"].keys()) if samples else []
    )
    REPORT["total_plot_count"] = total
    REPORT["extra_services"] = extra

    report_path = Path("logs/discovery_report.json")
    report_path.write_text(json.dumps(REPORT, indent=2, default=str))
    logger.info("\nDiscovery report written to %s", report_path)


if __name__ == "__main__":
    main()
