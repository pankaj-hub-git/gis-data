"""Configuration for the DDA GIS ingestion pipeline."""

import os
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.environ.get("DATABASE_URL", "")

# --- ArcGIS REST API endpoints ---
BASE_URL = "https://gis.dda.gov.ae/server/rest/services"

SERVICES = {
    "basic_land_base": {
        "url": f"{BASE_URL}/DDA/BASIC_LAND_BASE/MapServer",
        "layers": {
            "project_limit": 0,
            "project_limit_outline": 1,
            "plot": 2,
        },
        "max_record_count": 2000,
    },
    "zones_control": {
        "url": f"{BASE_URL}/DDA/ZonesControl/MapServer",
        "layers": {
            "project_limit_outline": 0,
            "project_limit": 1,
            "zones_control_reports": 2,
            "construction_status": 3,
        },
        "max_record_count": 1000,
    },
    "free_zone_projects": {
        "url": f"{BASE_URL}/DDA/FREE_ZONE_PROJECTS/MapServer",
        "layers": {
            "dda_project": 0,
        },
        "max_record_count": 1000,
    },
}

# Additional service folders to explore
EXTRA_FOLDERS = ["SITEPLAN", "BUILDING", "EMAAR", "ANALYSIS", "DEMARCATION", "DH", "DIS", "DPS"]

# Spatial reference: Dubai Local TM = 3997, output in WGS84 = 4326
INPUT_SR = 3997
OUTPUT_SR = 4326

# Dubai bounding box in WGS84
DUBAI_BBOX = {
    "xmin": 54.9,
    "ymin": 24.8,
    "xmax": 55.6,
    "ymax": 25.4,
}

# Scraping parameters
REQUEST_DELAY_SECONDS = 0.5
GRID_DIVISIONS = 10  # 10x10 = 100 tiles
HTTP_TIMEOUT = 60
MAX_RETRIES = 3
