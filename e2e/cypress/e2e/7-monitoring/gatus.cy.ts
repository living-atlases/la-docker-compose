import { serviceUrl } from "../../support/services";
import { pageRenders, skipIfMissing } from "../../support/checks";

// Gatus is the deployment's own health dashboard. If its API answers with a populated
// endpoint list, the monitoring layer itself is up (and Layer 1's gate has data to read).
describe("Monitoring (Gatus)", () => {
  before(function () {
    skipIfMissing("gatus", this);
  });

  it("gatus API returns a populated endpoint status list", () => {
    cy.request(serviceUrl("gatus", "/api/v1/endpoints/statuses")).then((resp) => {
      expect(resp.status).to.eq(200);
      // Accept both API shapes (bare array, or { endpoints: [...] }).
      const list = Array.isArray(resp.body) ? resp.body : resp.body?.endpoints;
      expect(list, "gatus endpoint list").to.be.an("array");
      expect(list.length, "monitored endpoints").to.be.greaterThan(0);
    });
  });

  it("gatus dashboard renders", () => {
    cy.visit(serviceUrl("gatus", "/"));
    pageRenders();
  });
});
