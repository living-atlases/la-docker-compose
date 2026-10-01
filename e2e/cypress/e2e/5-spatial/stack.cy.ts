import { serviceUrl } from "../../support/services";
import { linkedAssetsLoad, skipIfMissing } from "../../support/checks";

// The spatial stack end to end, read-only: spatial-service ws, GeoServer and the hub's own files.
// Each check is a failure that a healthy container and a 200 on /ws/fields did not catch:
//   - GeoServer crashing (SIGSEGV, exit 139) on WMS GetCapabilities with a too-small -Xss;
//   - the LayersDB store pointing at a host that is not PostGIS (a data dir copied from a VM keeps
//     host=localhost): every area (ALA:Objects) and intersect then fails while layers still draw;
//   - a layer published in spatial-service but missing or broken in GeoServer;
//   - a portal's own layout assets (css/js/icons) 404 in a jar install, leaving the hub unstyled;
//   - a layer with no classification, listed as "undefined / undefined" in the hub's layer tree.
// Data comes from the deployment itself (its layers, fields and areas), never from fixtures.
const ws = (path: string) => serviceUrl("spatial", `/ws${path}`);
const wms = (query: string) =>
  serviceUrl("spatial", `/geoserver/wms?service=WMS&version=1.1.1&${query}`);
const WORLD = "srs=EPSG:4326&bbox=-180,-90,180,90&width=64&height=32";

interface Layer {
  id: number | string;
  name: string;
  displayname: string;
  enabled: boolean;
  classification1?: string;
}
interface Field {
  id: string;
  spid: string;
  enabled: boolean;
  namesearch: boolean;
  intersect: boolean;
  type: string;
}
interface SpatialObject {
  pid: string;
  name: string;
  centroid: string;
}

function expectImage(url: string, tolerate: RegExp | null = null): void {
  cy.request({ url, failOnStatusCode: false, encoding: "binary" }).then((resp) => {
    expect(resp.status, `GET ${url}`).to.eq(200);
    if (tolerate && tolerate.test(String(resp.body))) return;
    // GeoServer answers errors as 200 + a ServiceException XML: the content type tells them apart.
    expect(String(resp.headers["content-type"]), `content type of ${url}`).to.match(/^image\//);
  });
}

describe("Spatial stack (spatial-service, GeoServer, hub)", () => {
  let layers: Layer[] = [];
  let fields: Field[] = [];
  let area: SpatialObject | undefined;

  before(function () {
    skipIfMissing("spatial", this);
    cy.request(ws("/layers")).then((r) => {
      layers = (r.body as Layer[]).filter((l) => l.enabled !== false);
    });
    cy.request(ws("/fields")).then((r) => {
      fields = (r.body as Field[]).filter((f) => f.enabled !== false);
      // An area to draw and intersect at: the first object of the first searchable contextual field.
      const f = fields.find((x) => x.namesearch && x.type === "c");
      if (f) {
        cy.request(ws(`/field/${f.id}?pageSize=1`)).then((fr) => {
          area = fr.body.objects?.[0];
        });
      }
    });
  });

  it("publishes layers and fields", () => {
    expect(layers.length, "enabled layers").to.be.greaterThan(0);
    expect(fields.length, "enabled fields").to.be.greaterThan(0);
  });

  it("every layer the hub lists has a classification (no 'undefined / undefined')", () => {
    // The hub lists a layer through its enabled fields: a layer whose fields are all disabled
    // (e.g. one kept only for the gazetteer) is not shown, so its classification does not matter.
    const listed = new Set(fields.map((f) => String(f.spid)));
    const missing = layers
      .filter((l) => listed.has(String(l.id)))
      .filter((l) => !l.classification1 || !String(l.classification1).trim())
      .map((l) => `${l.name} (${l.displayname})`);
    expect(missing, "layers without classification1").to.deep.eq([]);
  });

  it("GeoServer WMS GetCapabilities answers", () => {
    cy.request({ url: wms("request=GetCapabilities"), timeout: 120000 }).then((r) => {
      expect(r.status).to.eq(200);
      expect(String(r.body)).to.contain("WMT_MS_Capabilities");
    });
  });

  it("GeoServer draws every enabled layer and its legend", () => {
    layers.forEach((l) => {
      const name = encodeURIComponent(`ALA:${l.name}`);
      expectImage(wms(`request=GetMap&layers=${name}&styles=&format=image/png&transparent=true&${WORLD}`));
      // A contextual layer with thousands of classes (e.g. municipalities) has no drawable legend:
      // GeoServer refuses it with MaxMemoryExceeded. That is the layer, not a broken stack.
      expectImage(wms(`request=GetLegendGraphic&format=image/png&layer=${name}`), /MaxMemoryExceeded/);
    });
  });

  it("an area draws through ALA:Objects (GeoServer -> LayersDB)", function () {
    if (!area) this.skip();
    expectImage(
      wms(
        `request=GetMap&layers=ALA:Objects&styles=&format=image/png&transparent=true&${WORLD}` +
          `&viewparams=s:${area!.pid}`,
      ),
    );
  });

  it("the gazetteer finds that area by name, also with non-ASCII text", function () {
    if (!area) this.skip();
    cy.request(ws(`/search?q=${encodeURIComponent(area!.name)}&limit=50`)).then((r) => {
      const results = Array.isArray(r.body) ? r.body : r.body.results;
      expect(results.map((o: SpatialObject) => String(o.pid)), "search results").to.include(
        String(area!.pid),
      );
    });
    // An unencoded or mis-decoded UTF-8 query used to answer 400.
    cy.request(ws(`/search?q=${encodeURIComponent("ñá")}&limit=1`)).its("status").should("eq", 200);
  });

  it("intersects the area's centroid with the intersectable fields", function () {
    if (!area) this.skip();
    const m = String(area!.centroid).match(/POINT\(([-\d.]+) ([-\d.]+)\)/);
    const ids = fields.filter((f) => f.intersect).slice(0, 5).map((f) => f.id);
    if (!m || !ids.length) this.skip();
    cy.request(ws(`/intersect/${ids.join(",")}/${m![2]}/${m![1]}`)).then((r) => {
      expect(r.status).to.eq(200);
      expect(r.body, "intersect results").to.be.an("array").and.have.length(ids.length);
    });
  });

  it("the hub page loads its own stylesheets and scripts", function () {
    // Where the hub is login-gated, '/' redirects to the IdP and there is no hub page to check
    // without logging in (hub.cy.ts covers it under ENABLE_AUTH_TESTS).
    cy.request({ url: serviceUrl("spatial", "/"), followRedirect: false }).then((r) => {
      if (r.status >= 300 && r.status < 400) {
        this.skip();
      }
      linkedAssetsLoad(serviceUrl("spatial", "/"));
    });
  });

  it("the hub's layer-tree icons load", () => {
    ["icon_contextual-layer.png", "icon_grid-layer.png"].forEach((icon) =>
      expectImage(serviceUrl("spatial", `/assets/${icon}`)),
    );
  });
});
