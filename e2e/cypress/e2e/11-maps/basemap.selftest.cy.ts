import {
  analyseTile,
  expandTileTemplate,
  hasCartoKey,
  isCartoTemplate,
  MAX_OFF_COLOUR_SHARE,
  recordsHubTileTemplate,
  speciesHubTileTemplate,
  tileFor,
} from "../../support/basemap";

// Offline self-test for support/basemap.ts: no deployment and no CARTO needed, so the rules
// basemap.cy.ts relies on are verified even on a runner without outbound access.

const CARTO = "https://basemaps.cartocdn.com/rastertiles/light_all/{z}/{x}/{y}.png";

/** A flat 256x256 tile, optionally with a dark block standing in for watermark text. */
function tile(withText: boolean): Uint8ClampedArray {
  const w = 256;
  const px = new Uint8ClampedArray(w * w * 4);
  for (let i = 0; i < w * w; i += 1) {
    px.set([212, 218, 220, 255], i * 4);
  }
  if (withText) {
    for (let y = 120; y < 136; y += 1) {
      for (let x = 40; x < 216; x += 1) {
        if ((x + y) % 3 === 0) px.set([120, 120, 120, 255], (y * w + x) * 4);
      }
    }
  }
  return px;
}

describe("basemap helpers (offline)", () => {
  it("finds the tile containing a point", () => {
    expect(tileFor(0, 0, 1)).to.deep.eq({ z: 1, x: 1, y: 1 });
    expect(tileFor(51.5, -0.12, 10)).to.deep.eq({ z: 10, x: 511, y: 340 });
  });

  it("expands a Leaflet template, keeping the key", () => {
    expect(expandTileTemplate(`${CARTO}?key=abc`, { z: 8, x: 35, y: 159 })).to.eq(
      "https://basemaps.cartocdn.com/rastertiles/light_all/8/35/159.png?key=abc",
    );
    expect(
      expandTileTemplate("https://{s}.tile.example/{z}/{x}/{y}{r}.png", { z: 1, x: 0, y: 1 }, "bcd"),
    ).to.eq("https://b.tile.example/1/0/1.png");
  });

  it("recognises CARTO templates and their key", () => {
    expect(isCartoTemplate(CARTO)).to.eq(true);
    expect(
      isCartoTemplate("https://cartodb-basemaps-{s}.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png"),
    ).to.eq(true);
    expect(isCartoTemplate("https://tile.openstreetmap.org/{z}/{x}/{y}.png")).to.eq(false);
    expect(hasCartoKey(CARTO)).to.eq(false);
    expect(hasCartoKey(`${CARTO}?key=`)).to.eq(false);
    expect(hasCartoKey(`${CARTO}?key=abc`)).to.eq(true);
  });

  it("reads the template out of the records hub page", () => {
    const html = `
      var defaultBaseLayer = L.tileLayer("${CARTO}?key=a&amp;b=1", {
            attribution: "&copy; CARTO",
            subdomains: "abcd",
            mapid: "",
        });`;
    expect(recordsHubTileTemplate(html)).to.deep.eq({
      template: `${CARTO}?key=a&b=1`,
      subdomains: "abcd",
    });
    expect(recordsHubTileTemplate("<html>no map</html>")).to.eq(null);
  });

  it("reads the template out of the species page", () => {
    const html = `var SHOW_CONF = { defaultMapUrl: "${CARTO}", defaultMapAttr: "x" };`;
    expect(speciesHubTileTemplate(html)).to.deep.eq({ template: CARTO, subdomains: "" });
    expect(speciesHubTileTemplate("<html>no map</html>")).to.eq(null);
  });

  it("passes a flat ocean tile", () => {
    const v = analyseTile(tile(false), 256, 256);
    expect(v.offColourShare).to.eq(0);
    expect(v.transparentShare).to.eq(0);
  });

  it("flags a tile with text drawn on it", () => {
    const v = analyseTile(tile(true), 256, 256);
    expect(v.offColourShare).to.be.greaterThan(MAX_OFF_COLOUR_SHARE);
  });

  it("reports a fully transparent tile", () => {
    const v = analyseTile(new Uint8ClampedArray(16 * 16 * 4), 16, 16);
    expect(v.transparentShare).to.eq(1);
  });
});
