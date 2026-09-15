import { hubs } from "../../support/services";
import { pageRenders } from "../../support/checks";

// A data hub is an extra front-end (records, and optionally species and regions) that
// shows a data_hub_uid-filtered subset of the portal's data. In docker-compose each hub
// runs in its OWN containers, with its config written to a host directory that carries
// the hub name and mounted onto the fixed path the stock image reads. This spec is the
// cheapest check that the mount, the vhost and the container actually line up.
describe("Data hubs are reachable", () => {
  const declared = hubs();

  if (declared.length === 0) {
    it("no data hubs declared in this deployment", () => {
      cy.log("e2e-targets has no hubs; nothing to check");
    });
    return;
  }

  declared.forEach((hub) => {
    describe(`hub ${hub.key}`, () => {
      Object.entries(hub.services).forEach(([key, base]) => {
        it(`${key} serves a page`, () => {
          // Fetch first so a 5xx reports the app's own error page rather than dying
          // inside cy.visit with a bare status code (same reasoning as 2-biocache).
          cy.request({ url: base, failOnStatusCode: false }).then((resp) => {
            expect(
              resp.status,
              `GET ${base} — first 500 chars: ` +
                `${String(resp.body).replace(/\s+/g, " ").slice(0, 500)}`,
            ).to.be.lessThan(400);
          });
          cy.visit(base);
          pageRenders();
        });
      });
    });
  });
});
