import { serviceUrl } from "../../support/services";
import { skipIfMissing } from "../../support/checks";

// The legacy dashboard war (atlas-index's dashboard-ui replaces it once it has an image).
// It only exists in the topologies that enable it: skipIfMissing keeps the default build green.
describe("Dashboard (portal stats)", () => {
  it("renders its stats page through its vhost", function () {
    skipIfMissing("dashboard", this);
    cy.request({ url: serviceUrl("dashboard", "/"), failOnStatusCode: false }).then((resp) => {
      expect(resp.status, "dashboard /").to.eq(200);
      // Not just any 200: #totalRecords is the first panel of the page itself, so a branding
      // or proxy page answering in its place fails here instead of passing as the dashboard.
      expect(resp.body, "dashboard page body").to.contain('id="totalRecords"');
    });
  });
});
