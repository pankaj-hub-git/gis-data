# Dubai DDA GIS Data Pipeline

Ingests plot polygons, project boundaries, and construction status from the Dubai DDA ArcGIS Server into a PostGIS-enabled Supabase database.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your Supabase connection string
```

## Usage

### 1. Initialize database
```bash
python -m pipeline.setup_db
```

### 2. Discover API fields
```bash
python -m pipeline.discover
# Check logs/discovery_report.json then update pipeline/field_map.py if needed
```

### 3. Ingest MVP (Dubai Hills + Business Bay)
```bash
python -m pipeline.ingest_plots --projects "DUBAI HILLS" "BUSINESS BAY"
```

### 4. Full Dubai scrape
```bash
python -m pipeline.ingest_plots --full
# Resume if interrupted:
python -m pipeline.ingest_plots --full --resume
```

### 5. Ingest auxiliary layers
```bash
python -m pipeline.ingest_layers --all
python -m pipeline.ingest_layers --explore  # discover more services
```

### 6. Run enrichment
```bash
python -m pipeline.enrich
```

### 7. Daily updates (cron)
```bash
# Manual run:
python -m pipeline.daily_update

# Cron (2 AM GST = 10 PM UTC):
# 0 22 * * * cd /path/to/gis-data && /path/to/python -m pipeline.daily_update >> logs/cron.log 2>&1
```

## Verification queries

```sql
SELECT COUNT(*) FROM bronze.dda_plots;

SELECT plot_number, project_name, max_height, land_use, ST_AsGeoJSON(geometry)
FROM bronze.dda_plots
WHERE project_name LIKE '%DUBAI HILLS%'
LIMIT 5;

SELECT * FROM bronze.plot_summary
WHERE project_name LIKE '%DUBAI HILLS%';
```
