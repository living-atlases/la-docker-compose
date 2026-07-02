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

  it("spatial hub renders with a map container", function () {
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
    pageRenders();
    cy.get("#map, .leaflet-container, [class*='map'], [id*='map']", {
      timeout: 20000,
    }).should("exist");
  });
});
