#!/usr/bin/env bash
# Re-download everything in data/raw/ that does not depend on a chosen study site.
#
# Deliberately does NOT fetch any orthomosaic or CHM. Those are ~1.2 GB and ~35 MB per
# mission, and which mission to pull is the Task 1.2 judgment call. Fetch those by hand
# once the site is chosen.
#
# Usage:  bash src/fetch_raw_data.sh
# Safe to re-run; it overwrites in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRONE_DIR="$REPO_ROOT/data/raw/ofo_drone_catalog"
GROUND_DIR="$REPO_ROOT/data/raw/ofo_ground_ref_catalog"

CYVERSE_META="https://data.cyverse.org/dav-anon/iplant/projects/ofo/public/metadata"
STAC_ITEMS="https://stac.cyverse.org/collections/Open%20Forest%20Observatory/items?limit=100"
OFO_SITE="https://openforestobservatory.org"

mkdir -p "$DRONE_DIR/mission-metadata-by-project" "$GROUND_DIR" "$REPO_ROOT/data/processed"

echo "==> Mission footprint polygons (GeoPackage)"
for f in all-mission-polygons-w-metadata.gpkg all-sub-mission-polygons-w-metadata.gpkg; do
  curl -fsSL --max-time 300 "$CYVERSE_META/$f" -o "$DRONE_DIR/$f"
  echo "    $f"
done

echo "==> Per-project mission metadata (CSV)"
for proj in 2019-focal 2020-dispersal 2020-fuels 2020-ucnrs 2021-early-regen \
            2021-tnc-yuba 2022-early-regen 2023-ny-ofo 2023-tahoe-aspen 2023-ucnrs \
            2024-ofo2 2024-ucnrs; do
  curl -fsSL --max-time 120 \
    "$CYVERSE_META/by-imagery-project/mission-full-metadata_$proj.csv" \
    -o "$DRONE_DIR/mission-metadata-by-project/$proj.csv"
done
echo "    12 project files"

# The STAC /search endpoint returns empty for bbox queries, so page the items endpoint
# and stitch the feature arrays into one FeatureCollection.
echo "==> STAC items, paged into one GeoJSON"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="$STAC_ITEMS"
page=0
while [ -n "$url" ] && [ "$page" -lt 20 ]; do
  curl -fsSL --max-time 180 "$url" -o "$tmp/page$page.json"
  url=$(sed 's/.*"rel":"next"[^}]*"href":"//;s/".*//' "$tmp/page$page.json" \
        | grep '^https' | sed 's/ /%20/g' || true)
  page=$((page + 1))
done
{
  printf '{"type":"FeatureCollection","features":['
  first=1
  for f in "$tmp"/page*.json; do
    body=$(sed 's/.*"features":\[//; s/\],"numberReturned".*//' "$f")
    [ -z "$body" ] && continue
    [ "$first" -eq 0 ] && printf ','
    printf '%s' "$body"
    first=0
  done
  printf ']}'
} > "$DRONE_DIR/stac_items_ofo.geojson"
echo "    $(grep -o '"id":"[0-9]\{6\}"' "$DRONE_DIR/stac_items_ofo.geojson" | wc -l) items"

echo "==> Ground reference catalog (metadata only — stem files are not published yet)"
curl -fsSL --max-time 120 \
  "$OFO_SITE/ground-plot-catalog-datatable/ground-plot-catalog-datatable.html" \
  -o "$GROUND_DIR/ground-plot-catalog-datatable.html"
curl -fsSL --max-time 120 \
  "$OFO_SITE/ground-plot-catalog-map/ground-plot-catalog-map.html" \
  -o "$GROUND_DIR/ground-plot-catalog-map.html"

echo "==> Plot centroids, derived from the catalog map's marker layer"
# The catalog map is an R leaflet widget. Its addMarkers call carries one marker per plot:
# a latitude array, then a longitude array, then popups holding the plot-detail links. The
# three are in the same order, so they zip into a table. Checked against plot 0068, whose
# marker lands on Emerald Point at 38.96656, -120.08741.
mk="$tmp/markers.txt"
grep -o '"method":"addMarkers","args":\[.*' "$GROUND_DIR/ground-plot-catalog-map.html" > "$mk"
grep -o 'plot-details/[0-9]\{4\}' "$mk" | sed 's|plot-details/||' | head -296 > "$tmp/ids.txt"
sed 's/.*"addMarkers","args":\[\[//; s/\].*//' "$mk" \
  | tr ',' '\n' | grep -E '^-?[0-9.]+$' > "$tmp/lats.txt"
sed 's/.*"addMarkers","args":\[\[//; s/^[^]]*\],\[//; s/\].*//' "$mk" \
  | tr ',' '\n' | grep -E '^-?[0-9.]+$' > "$tmp/lons.txt"
{
  echo "plot_id,lat,lon"
  paste -d',' "$tmp/ids.txt" "$tmp/lats.txt" "$tmp/lons.txt"
} > "$GROUND_DIR/plot_centroids_derived.csv"
echo "    $(($(wc -l < "$GROUND_DIR/plot_centroids_derived.csv") - 1)) plots"

echo "==> Plot 0068 (Emerald Point) detail pages, for reference"
curl -fsSL --max-time 120 "$OFO_SITE/ground-plot-details-datatables/0068.html" \
  -o "$GROUND_DIR/plot-0068-attributes.html"
curl -fsSL --max-time 120 "$OFO_SITE/ground-plot-details-maps/0068.html" \
  -o "$GROUND_DIR/plot-0068-map.html"

echo
echo "Done. data/raw is $(du -sh "$REPO_ROOT/data/raw" | cut -f1)."
