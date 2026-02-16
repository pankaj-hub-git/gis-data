"""Shared HTTP client with retry logic for ArcGIS REST API."""

import asyncio
import logging
import time

import httpx

from pipeline.config import HTTP_TIMEOUT, MAX_RETRIES, REQUEST_DELAY_SECONDS

logger = logging.getLogger(__name__)

# Rate-limit: track last request time
_last_request_time = 0.0


def _get_client() -> httpx.Client:
    return httpx.Client(
        timeout=HTTP_TIMEOUT,
        headers={
            "User-Agent": "DDA-GIS-Pipeline/1.0",
            "Referer": "https://gis.dda.gov.ae/",
        },
        follow_redirects=True,
    )


def fetch_json(url: str, params: dict | None = None) -> dict:
    """Fetch JSON from an ArcGIS REST endpoint with retry and rate limiting."""
    global _last_request_time

    params = params or {}
    if "f" not in params:
        params["f"] = "json"

    for attempt in range(1, MAX_RETRIES + 1):
        # Rate limiting
        elapsed = time.monotonic() - _last_request_time
        if elapsed < REQUEST_DELAY_SECONDS:
            time.sleep(REQUEST_DELAY_SECONDS - elapsed)

        try:
            with _get_client() as client:
                _last_request_time = time.monotonic()
                resp = client.get(url, params=params)
                resp.raise_for_status()
                data = resp.json()

                # ArcGIS sometimes returns 200 with an error body
                if "error" in data:
                    code = data["error"].get("code", "?")
                    msg = data["error"].get("message", "Unknown")
                    logger.warning("ArcGIS error (code=%s): %s [attempt %d]", code, msg, attempt)
                    if attempt < MAX_RETRIES:
                        time.sleep(2 ** attempt)
                        continue
                    raise RuntimeError(f"ArcGIS error after {MAX_RETRIES} attempts: {msg}")

                return data

        except httpx.HTTPStatusError as exc:
            logger.warning("HTTP %s from %s [attempt %d]", exc.response.status_code, url, attempt)
            if attempt < MAX_RETRIES:
                time.sleep(2 ** attempt)
            else:
                raise
        except httpx.RequestError as exc:
            logger.warning("Request error: %s [attempt %d]", exc, attempt)
            if attempt < MAX_RETRIES:
                time.sleep(2 ** attempt)
            else:
                raise

    raise RuntimeError("Unreachable")


def fetch_geojson(url: str, params: dict | None = None) -> dict:
    """Fetch GeoJSON from an ArcGIS query endpoint."""
    params = params or {}
    params["f"] = "geojson"
    return fetch_json(url, params)
