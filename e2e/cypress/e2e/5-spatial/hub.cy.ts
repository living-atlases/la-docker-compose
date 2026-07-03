import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Spatial hub — heavy on client-side JS (Leaflet map). In this deployment '/' is CAS-gated,
// so the map assertion runs only under ENABLE_AUTH_TESTS (after cy.login). The default no-auth
// smoke just confirms the hub is reachable and hands off to CAS.
describe("Spatial hub", () => {
  before(function () {
    skipIfMissing("spatial", this);
  });

  it("spatial ws fields respond", () => {
    apiOk(serviceUrl("spatial", "/ws/fields"));
  });

  it("spatial hub renders the Leaflet map", function () {
    const authOn = String(Cypress.env("ENABLE_AUTH_TESTS")) === "true";
    if (!authOn) {
      // '/' is CAS-gated: unauthenticated it 302s to the CAS login. Smoke = reachable, no 5xx.
      cy.request({ url: serviceUrl("spatial", "/"), followRedirect: false }).then(
        (resp) => {
          expect(resp.status, "spatial hub reachable").to.be.lessThan(400);
        },
      );
      return;
    }
    cy.login();
    cy.visit(serviceUrl("spatial", "/"));
    // Landed on the hub SPA shell (server-rendered <sp-app>), not bounced to the CAS login form.
    cy.get("sp-app", { timeout: 30000 }).should("exist");
    pageRenders();
    // angular-leaflet initialises #map (class leaflet-container) and its .leaflet-map-pane
    // synchronously on load — independent of external OSM tiles, so this stays robust in CI.
    // (Tiles from openstreetmap.org are a bonus, not asserted: CI may lack outbound access.)
    cy.get("#map.leaflet-container", { timeout: 30000 }).should("be.visible");
    cy.get("#map .leaflet-map-pane", { timeout: 30000 }).should("exist");
  });
});
