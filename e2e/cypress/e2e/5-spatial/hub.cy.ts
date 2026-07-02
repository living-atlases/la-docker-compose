import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Spatial hub — heavy on client-side JS (Leaflet map). A blank map container usually means
// a JS/init failure, so we assert the map element actually mounts.
describe("Spatial hub", () => {
  before(function () {
    skipIfMissing("spatial", this);
  });

  it("spatial ws fields respond", () => {
    apiOk(serviceUrl("spatial", "/ws/fields"));
  });

  it("spatial hub renders with a map container", () => {
    cy.visit(serviceUrl("spatial", "/"));
    pageRenders();
    cy.get("#map, .leaflet-container, [class*='map'], [id*='map']", {
      timeout: 20000,
    }).should("exist");
  });
});
