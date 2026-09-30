import { hasService, hubs, serviceUrl } from "../../support/services";
import { bieHasData } from "../../support/checks";
import {
  basemapIsClean,
  recordsHubTileTemplate,
  speciesHubTileTemplate,
} from "../../support/basemap";

// The basemap must look right on a deployment that set no carto_api_key, which is every
// testing inventory. CARTO answers a keyless tile with 200 and "API KEY REQUIRED" drawn on
// it, so the hubs, data hubs included, showed the watermark while everything stayed green.
// This spec reads the tile URL each hub actually serves and looks at the tile itself; see
// support/basemap.ts. The pixel logic is covered offline by basemap.selftest.cy.ts.
//
// The tiles come from CARTO, not from this deployment: the runner needs outbound HTTPS to
// basemaps.cartocdn.com, as every visitor's browser does.

function templateFrom(
  label: string,
  pageUrl: string,
  extract: typeof recordsHubTileTemplate,
): Cypress.Chainable<{ template: string; subdomains: string }> {
  return cy.request({ url: pageUrl, failOnStatusCode: false }).then((resp) => {
    expect(resp.status, `${label}: GET ${pageUrl}`).to.be.lessThan(400);
    const found = extract(String(resp.body));
    expect(found, `${label}: ${pageUrl} hands its map a basemap tile URL`).to.not.eq(null);
    return found as { template: string; subdomains: string };
  });
}

/** First taxon guid in the bie index, for a species page to open. */
function anyGuid(): Cypress.Chainable<string> {
  return cy.request(serviceUrl("speciesWs", "/search?q=Acacia&pageSize=1")).then((resp) => {
    const guid = resp.body?.searchResults?.results?.[0]?.guid;
    expect(guid, "a taxon guid from species-ws").to.be.a("string");
    return guid as string;
  });
}

describe("Basemap tiles render without a CARTO watermark", () => {
  it("records hub: occurrence map", function () {
    if (!hasService("records")) {
      this.skip();
    }
    templateFrom(
      "records",
      serviceUrl("records", "/occurrences/search?q=*:*"),
      recordsHubTileTemplate,
    ).then((found) => basemapIsClean("records", found));
  });

  // The species page is the only one that carries the map, and it needs a taxon to open.
  it("species hub: species page map", function () {
    if (!hasService("species") || !hasService("speciesWs") || !bieHasData()) {
      this.skip();
    }
    anyGuid().then((guid) =>
      templateFrom(
        "species",
        serviceUrl("species", `/species/${encodeURI(guid)}`),
        speciesHubTileTemplate,
      ).then((found) => basemapIsClean("species", found)),
    );
  });

  // A data hub renders its own config from its own copy of the role, so a key that reaches
  // the portal is no proof it reached the hub.
  hubs().forEach((hub) => {
    it(`${hub.key} records hub: occurrence map`, function () {
      const base = (hub.services.records || "").replace(/\/+$/, "");
      if (!base) {
        this.skip();
      }
      const label = `${hub.key} records`;
      templateFrom(label, `${base}/occurrences/search?q=*:*`, recordsHubTileTemplate).then(
        (found) => basemapIsClean(label, found),
      );
    });

    it(`${hub.key} species hub: species page map`, function () {
      const base = (hub.services.species || "").replace(/\/+$/, "");
      if (!base || !hasService("speciesWs") || !bieHasData()) {
        this.skip();
      }
      const label = `${hub.key} species`;
      anyGuid().then((guid) =>
        templateFrom(label, `${base}/species/${encodeURI(guid)}`, speciesHubTileTemplate).then(
          (found) => basemapIsClean(label, found),
        ),
      );
    });
  });
});
