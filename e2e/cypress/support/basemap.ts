// Basemap tile checks. Pure functions first (covered offline by basemap.selftest.cy.ts),
// Cypress glue last.
//
// CARTO enforces its API key by WATERMARKING, not by refusing: a keyless tile request still
// answers 200 with a valid PNG, only with "API KEY REQUIRED" drawn into it. So every check
// a status code can make is green over a map stamped with that text on every tile, which is
// what the hubs showed in CI. What does tell the two apart is the picture itself: a tile of
// open ocean is one flat colour, and the watermark is the only thing that can put anything
// else in it.

/** Tiles over open ocean, far from any coast, island, label or graticule. */
export const OCEAN_POINTS: ReadonlyArray<{ name: string; lat: number; lon: number }> = [
  { name: "South Pacific", lat: -40, lon: -130 },
  { name: "South Indian Ocean", lat: -30, lon: 80 },
];

/** Zoom deep enough that no ocean-name label is drawn, shallow enough to stay cached. */
export const OCEAN_ZOOM = 8;

/** Slippy-map (Web Mercator, XYZ) tile containing a point. */
export function tileFor(lat: number, lon: number, z: number): { z: number; x: number; y: number } {
  const n = 2 ** z;
  const latRad = (lat * Math.PI) / 180;
  const x = Math.floor(((lon + 180) / 360) * n);
  const y = Math.floor(((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n);
  return { z, x, y };
}

/**
 * Expand a Leaflet tile URL template ({s}, {z}, {x}, {y}, {r}) into a concrete tile URL.
 * The first configured subdomain stands in for {s}, as Leaflet itself would for some tile.
 */
export function expandTileTemplate(
  template: string,
  tile: { z: number; x: number; y: number },
  subdomains = "abc",
): string {
  return template
    .replace(/\{s\}/g, subdomains.charAt(0) || "a")
    .replace(/\{z\}/g, String(tile.z))
    .replace(/\{x\}/g, String(tile.x))
    .replace(/\{y\}/g, String(tile.y))
    .replace(/\{r\}/g, "");
}

/** True when the template points at CARTO's tile servers, old (fastly) host included. */
export function isCartoTemplate(template: string): boolean {
  return /(^|\/\/|\.)(basemaps\.cartocdn\.com|cartodb-basemaps-[^./]*\.global\.ssl\.fastly\.net)/i.test(
    template,
  );
}

/** True when the template carries a CARTO key (`?key=` / `&key=` with a value). */
export function hasCartoKey(template: string): boolean {
  return /[?&]key=[^&#\s]+/.test(template);
}

/** Undo the HTML escaping GSP applies to `${...}` in the page, so `&amp;` is `&` again. */
function unescapeHtml(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&quot;/g, '"');
}

/**
 * The basemap template the biocache (records) hub hands Leaflet: the first argument of the
 * `L.tileLayer("...")` its search page renders from map.minimal.url, with the subdomains
 * that go with it. null when the page carries none (a hub that dropped the map).
 */
export function recordsHubTileTemplate(html: string): { template: string; subdomains: string } | null {
  const m = html.match(/L\.tileLayer\(\s*["']([^"']+)["']\s*,\s*\{([\s\S]{0,600}?)\}\s*\)/);
  if (!m) return null;
  const sub = m[2].match(/subdomains\s*:\s*["']([^"']*)["']/);
  return { template: unescapeHtml(m[1]), subdomains: sub ? sub[1] : "" };
}

/** The basemap template the species (bie) hub hands Leaflet: SHOW_CONF.defaultMapUrl. */
export function speciesHubTileTemplate(html: string): { template: string; subdomains: string } | null {
  const m = html.match(/defaultMapUrl\s*:\s*["']([^"']+)["']/);
  return m ? { template: unescapeHtml(m[1]), subdomains: "" } : null;
}

export interface TileVerdict {
  width: number;
  height: number;
  /** Share of pixels that differ from the tile's dominant colour. */
  offColourShare: number;
  /** Share of fully transparent pixels. */
  transparentShare: number;
}

/**
 * Measure how far an RGBA tile is from one flat colour. `tolerance` is the largest
 * per-channel difference still counted as the same colour: PNG is lossless, so a clean
 * ocean tile is exact, and the tolerance only absorbs dithering, not text.
 */
export function analyseTile(
  rgba: ArrayLike<number>,
  width: number,
  height: number,
  tolerance = 6,
): TileVerdict {
  const total = width * height;
  const counts = new Map<number, number>();
  let transparent = 0;
  for (let i = 0; i < total * 4; i += 4) {
    if (rgba[i + 3] === 0) transparent += 1;
    const key = ((rgba[i] << 24) | (rgba[i + 1] << 16) | (rgba[i + 2] << 8) | rgba[i + 3]) >>> 0;
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  let mode = 0;
  let modeCount = -1;
  counts.forEach((c, k) => {
    if (c > modeCount) {
      mode = k;
      modeCount = c;
    }
  });
  const ref = [(mode >>> 24) & 255, (mode >>> 16) & 255, (mode >>> 8) & 255, mode & 255];
  let off = 0;
  for (let i = 0; i < total * 4; i += 4) {
    for (let c = 0; c < 4; c += 1) {
      if (Math.abs(rgba[i + c] - ref[c]) > tolerance) {
        off += 1;
        break;
      }
    }
  }
  return {
    width,
    height,
    offColourShare: total ? off / total : 0,
    transparentShare: total ? transparent / total : 0,
  };
}

/** Above this share of off-colour pixels an ocean tile has something drawn on it. */
export const MAX_OFF_COLOUR_SHARE = 0.005;

/** Decode a base64 image in the browser and hand back its pixels. */
export function decodeImage(
  base64: string,
  contentType: string,
): Promise<{ rgba: Uint8ClampedArray; width: number; height: number }> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement("canvas");
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        reject(new Error("no 2d canvas context"));
        return;
      }
      ctx.drawImage(img, 0, 0);
      const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
      resolve({ rgba: data.data, width: canvas.width, height: canvas.height });
    };
    img.onerror = () => reject(new Error("the tile does not decode as an image"));
    img.src = `data:${contentType};base64,${base64}`;
  });
}

/**
 * Assert the basemap a hub serves shows clean tiles: every ocean tile answers 200 with an
 * image, and the image is one flat colour, i.e. carries no "API KEY REQUIRED" watermark.
 * Non-CARTO templates are the inventory's own choice and only need to load.
 */
export function basemapIsClean(
  label: string,
  found: { template: string; subdomains: string },
): void {
  const { template, subdomains } = found;
  const carto = isCartoTemplate(template);
  const keyNote = hasCartoKey(template)
    ? "The URL carries a key, so the key itself is being refused (wrong, revoked or over quota)."
    : "The URL carries no key: set carto_api_key in [all:vars] (free for non-commercial use " +
      "at https://carto.com/basemaps/apikey/), or point default_map_url / map_mininal_url " +
      "at a keyless provider.";
  cy.log(`${label}: basemap ${template.replace(/key=[^&#]+/, "key=***")}`);

  OCEAN_POINTS.forEach((p) => {
    const url = expandTileTemplate(template, tileFor(p.lat, p.lon, OCEAN_ZOOM), subdomains);
    const shown = url.replace(/key=[^&#]+/, "key=***");
    cy.request({ url, encoding: "base64", failOnStatusCode: false, log: false }).then((resp) => {
      expect(resp.status, `${label}: GET ${shown}`).to.eq(200);
      const type = String(resp.headers["content-type"] || "");
      expect(type, `${label}: ${shown} content-type`).to.match(/^image\//);
      if (!carto) return;
      cy.wrap(decodeImage(String(resp.body), type.split(";")[0]), { log: false }).then(
        (img) => {
          const { rgba, width, height } = img as {
            rgba: Uint8ClampedArray;
            width: number;
            height: number;
          };
          const v = analyseTile(rgba, width, height);
          expect(v.transparentShare, `${label}: ${p.name} tile is blank`).to.be.lessThan(1);
          expect(
            v.offColourShare,
            `${label}: the ${p.name} tile (${shown}) should be flat ocean, but ` +
              `${(v.offColourShare * 100).toFixed(1)}% of it is drawn over: CARTO's ` +
              `"API KEY REQUIRED" watermark. ${keyNote}`,
          ).to.be.at.most(MAX_OFF_COLOUR_SHARE);
        },
      );
    });
  });
}
