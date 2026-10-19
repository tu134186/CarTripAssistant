#!/usr/bin/env python3
"""Create offline PNG MBTiles from Shenzhen OSM GeoJSON road lines.
Data attribution: © OpenStreetMap contributors, ODbL.
This is a lightweight roads-only basemap, not a complete commercial map.
"""
import json, math, sqlite3, sys, io
from collections import defaultdict
from PIL import Image, ImageDraw, ImageFont

BBOX = (113.70, 22.35, 114.65, 22.90)
MIN_ZOOM, MAX_ZOOM = 10, 16
TILE = 256
HIGHWAYS = {
    "motorway": (7, "#d99b5f"), "trunk": (6, "#d9a96d"),
    "primary": (5, "#d9b57c"), "secondary": (4, "#b9bec5"),
    "tertiary": (3, "#9ba9ba"), "residential": (2, "#8395a9"),
    "unclassified": (2, "#8395a9"), "service": (1, "#607589"),
    "living_street": (1, "#8395a9"), "motorway_link": (3, "#d99b5f"),
    "trunk_link": (3, "#d9a96d"), "primary_link": (3, "#d9b57c"),
    "secondary_link": (2, "#b9bec5"), "tertiary_link": (2, "#9ba9ba"),
}
def world(lon, lat, z):
    n = 2 ** z
    lat = max(-85.051128, min(85.051128, lat))
    return ((lon + 180) / 360 * n * TILE,
            (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n * TILE)

def features(path):
    with open(path, encoding="utf-8") as stream:
        doc = json.load(stream)
    for feature in doc.get("features", []):
        tags = feature.get("properties") or {}
        kind = tags.get("highway")
        if kind not in HIGHWAYS:
            continue
        geometry = feature.get("geometry") or {}
        typ, coords = geometry.get("type"), geometry.get("coordinates") or []
        label = tags.get("name:zh") or tags.get("name") or ""
        if typ == "LineString":
            yield kind, label, coords
        elif typ == "MultiLineString":
            for line in coords:
                yield kind, label, line

def render(input_path, output_path):
    roads = list(features(input_path))
    labeled_roads = sum(1 for _, name, _ in roads if name)
    chinese_roads = sum(1 for _, name, _ in roads if any("\\u4e00" <= c <= "\\u9fff" for c in name))
    print("Named road segments:", labeled_roads, "Chinese-named:", chinese_roads, flush=True)
    print("Road segments:", len(roads), flush=True)
    if not roads:
        raise RuntimeError("No road features in Shenzhen extract")
    if chinese_roads == 0:
        raise RuntimeError("No Chinese road labels in Shenzhen source; refusing misleading map output")
    db = sqlite3.connect(output_path)
    db.executescript("""
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE UNIQUE INDEX metadata_name ON metadata(name);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles(zoom_level,tile_column,tile_row);
    """)
    db.executemany("INSERT INTO metadata VALUES (?,?)", [
        ("name", "Shenzhen Roads (OSM)"), ("type", "baselayer"),
        ("format", "png"), ("minzoom", str(MIN_ZOOM)),
        ("maxzoom", str(MAX_ZOOM)), ("bounds", ",".join(map(str, BBOX))),
        ("attribution", "© OpenStreetMap contributors"),
    ])
    try:
        font = ImageFont.truetype("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 12)
    except OSError:
        font = ImageFont.load_default()
    blank = Image.new("RGB", (TILE, TILE), "#172433")
    blank_buffer = io.BytesIO()
    blank.save(blank_buffer, format="PNG")
    blank_png = blank_buffer.getvalue()
    for z in range(MIN_ZOOM, MAX_ZOOM + 1):
        west, north = world(BBOX[0], BBOX[3], z)
        east, south = world(BBOX[2], BBOX[1], z)
        minx, maxx = int(west // TILE), int(east // TILE)
        miny, maxy = int(north // TILE), int(south // TILE)
        bucket = defaultdict(list)
        for kind, label, coords in roads:
            if len(coords) < 2:
                continue
            points = [world(p[0], p[1], z) for p in coords if len(p) >= 2]
            if len(points) < 2:
                continue
            xlo, xhi = max(minx, int(min(p[0] for p in points) // TILE) - 1), min(maxx, int(max(p[0] for p in points) // TILE) + 1)
            ylo, yhi = max(miny, int(min(p[1] for p in points) // TILE) - 1), min(maxy, int(max(p[1] for p in points) // TILE) + 1)
            for x in range(xlo, xhi + 1):
                for y in range(ylo, yhi + 1):
                    bucket[(x,y)].append((kind, label, points))
        count = 0
        for x in range(minx, maxx + 1):
            for y in range(miny, maxy + 1):
                entries = bucket.get((x,y), [])
                if not entries:
                    db.execute("INSERT INTO tiles VALUES (?,?,?,?)", (z,x,(2**z-1-y),blank_png))
                    count += 1
                    continue
                im = Image.new("RGB", (TILE, TILE), "#172433")
                draw = ImageDraw.Draw(im)
                labeled = set()
                for kind, label, points in sorted(entries, key=lambda entry: -HIGHWAYS[entry[0]][0]):
                    width, color = HIGHWAYS[kind]
                    coords = [(int(px - x*TILE), int(py - y*TILE)) for px,py in points]
                    draw.line(coords, fill=color, width=max(1, width * (z - 9) // 5), joint="curve")
                    if z >= 13 and label and label not in labeled and len(coords) >= 2:
                        mid = coords[len(coords)//2]
                        if 22 < mid[0] < 234 and 22 < mid[1] < 234:
                            # Limit labels per tile to keep roads readable.
                            if len(labeled) < (8 if z >= 15 else 4):
                                draw.text((mid[0] + 3, mid[1] + 3), str(label)[:18], font=font,
                                          fill="#eef3f7", stroke_width=2, stroke_fill="#172433")
                                labeled.add(label)
                out = io.BytesIO()
                im.save(out, format="PNG")
                db.execute("INSERT INTO tiles VALUES (?,?,?,?)", (z,x,(2**z-1-y),out.getvalue()))
                count += 1
        db.commit()
        print("Zoom", z, "tiles", count, flush=True)
    db.close()
    print("Rendered road map with", chinese_roads, "Chinese-named road segments", flush=True)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_shenzhen_mbtiles.py shenzhen.geojson output.mbtiles")
    render(sys.argv[1], sys.argv[2])
