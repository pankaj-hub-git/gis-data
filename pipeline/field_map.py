"""
Field mapping: ArcGIS field names → database column names.

After running `python -m pipeline.discover`, update these maps based on
the actual field names returned by the API.  The discover script prints
every field name — just match them here.

Common ArcGIS naming patterns for DDA:
  OBJECTID, PLOT_NO, PLOT_NUMBER, OLD_NUMBER, PROJECT_NAME, COMMUNITY_NAME,
  MASTER_DEVELOPER, PLOT_AREA_M2, PLOT_AREA_FT2, MAX_GFA_M2, MAX_GFA_FT2,
  MAX_HEIGHT, MAX_COVERAGE, LAND_USE, SITE_PLAN_ISSUE_DATE, SITE_PLAN_EXPIRY_DATE,
  SETBACK_FRONT_BLDG, SETBACK_REAR_BLDG, etc.
"""

# DB column → likely ArcGIS field name (case-insensitive matching done at runtime)
# Update these after running discovery and seeing actual field names.

PLOT_FIELD_MAP: dict[str, str] = {
    "objectid":              "OBJECTID",
    "plot_number":           "PLOT_NUMBER",
    "old_numbers":           "OLD_NUMBER",
    "project_name":          "PROJECT_NAME",
    "community_name":        "COMMUNITY_NAME",
    "master_developer":      "MASTER_DEVELOPER",
    "plot_area_sqm":         "PLOT_AREA_M2",
    "plot_area_sqft":        "PLOT_AREA_FT2",
    "max_gfa_sqm":           "MAX_GFA_M2",
    "max_gfa_sqft":          "MAX_GFA_FT2",
    "max_height":            "MAX_HEIGHT",
    "max_coverage":          "MAX_COVERAGE",
    "land_use":              "LAND_USE",
    "site_plan_issue_date":  "SITE_PLAN_ISSUE_DATE",
    "site_plan_expiry_date": "SITE_PLAN_EXPIRY_DATE",
    "setback_front_bldg":    "SETBACK_FRONT_BLDG",
    "setback_rear_bldg":     "SETBACK_REAR_BLDG",
    "setback_left_bldg":     "SETBACK_LEFT_BLDG",
    "setback_right_bldg":    "SETBACK_RIGHT_BLDG",
    "setback_front_podium":  "SETBACK_FRONT_PODIUM",
    "setback_rear_podium":   "SETBACK_REAR_PODIUM",
    "setback_left_podium":   "SETBACK_LEFT_PODIUM",
    "setback_right_podium":  "SETBACK_RIGHT_PODIUM",
    "status":                "STATUS",
}

PROJECT_FIELD_MAP: dict[str, str] = {
    "objectid":         "OBJECTID",
    "project_name":     "PROJECT_NAME",
    "project_number":   "PROJECT_NUMBER",
    "master_developer": "MASTER_DEVELOPER",
    "status":           "STATUS",
}

CONSTRUCTION_FIELD_MAP: dict[str, str] = {
    "objectid":             "OBJECTID",
    "project_name":         "PROJECT_NAME",
    "plot_number":          "PLOT_NUMBER",
    "construction_status":  "CONSTRUCTION_STATUS",
    "permit_number":        "PERMIT_NUMBER",
    "contractor":           "CONTRACTOR",
    "consultant":           "CONSULTANT",
}


def auto_match_fields(actual_fields: list[str], field_map: dict[str, str]) -> dict[str, str]:
    """Given a list of actual API field names and our expected map,
    return a corrected map using case-insensitive matching.

    Also tries common variations:
      PLOT_NO vs PLOT_NUMBER, AREA_M2 vs AREA_SQM, etc.
    """
    # Build lookup: uppercase → actual casing
    actual_upper = {f.upper(): f for f in actual_fields}

    matched = {}
    unmatched_db_cols = []

    for db_col, expected_api_field in field_map.items():
        upper = expected_api_field.upper()
        if upper in actual_upper:
            matched[db_col] = actual_upper[upper]
        else:
            # Try variations
            found = False
            variations = _variations(expected_api_field)
            for var in variations:
                if var.upper() in actual_upper:
                    matched[db_col] = actual_upper[var.upper()]
                    found = True
                    break
            if not found:
                unmatched_db_cols.append(db_col)

    return matched


def _variations(field: str) -> list[str]:
    """Generate common ArcGIS field name variations."""
    v = []
    # PLOT_NUMBER ↔ PLOT_NO ↔ PLOTNUMBER
    if field.endswith("_NUMBER"):
        v.append(field.replace("_NUMBER", "_NO"))
    if field.endswith("_NO"):
        v.append(field.replace("_NO", "_NUMBER"))
    # AREA_M2 ↔ AREA_SQM
    if "_M2" in field:
        v.append(field.replace("_M2", "_SQM"))
    if "_SQM" in field:
        v.append(field.replace("_SQM", "_M2"))
    if "_FT2" in field:
        v.append(field.replace("_FT2", "_SQFT"))
    if "_SQFT" in field:
        v.append(field.replace("_SQFT", "_FT2"))
    # With/without underscores
    v.append(field.replace("_", ""))
    # Shape.STArea() etc.
    if field == "OBJECTID":
        v.extend(["FID", "OID", "OBJECTID_1"])
    return v
