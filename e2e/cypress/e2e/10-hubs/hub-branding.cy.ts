import { hubs, targets } from "../../support/services";

// Branding is per hub: a hub that declares a branding_source of its own gets its own
// image, its own volume and its own nginx mount; a hub without one reuses the portal's
// through header_and_footer_baseurl. Both are legitimate, and the failure mode of the
// first silently degrades into the second (a mis-wired la_branding-assets-<pkg> mount
// serves the portal's assets), which no other spec would catch.
describe("Data hub branding", () => {
  const declared = hubs();

  if (declared.length === 0) {
    it("no data hubs declared in this deployment", () => {
      cy.log("nothing to check");
    });
    return;
  }

  const portalBranding = (targets().root || "").replace(/\/+$/, "");

  declared.forEach((hub) => {
    const branding = (hub.branding || "").replace(/\/+$/, "");

    it(`${hub.key} serves a branding footer`, function () {
      if (!branding) {
        this.skip();
      }
      cy.request({ url: `${branding}/footer.html`, failOnStatusCode: false }).then(
        (resp) => {
          expect(resp.status, `GET ${branding}/footer.html`).to.eq(200);
          expect(String(resp.body).trim().length, "footer is not empty").to.be.greaterThan(
            0,
          );
        },
      );
    });

    it(`${hub.key} branding is its own when it declares one`, function () {
      if (!branding || branding === portalBranding) {
        // Declares no branding of its own: reusing the portal's is the intended
        // behaviour, and there is nothing to distinguish.
        this.skip();
      }
      cy.request({ url: `${branding}/footer.html`, failOnStatusCode: false }).then(
        (hubResp) => {
          cy.request({
            url: `${portalBranding}/footer.html`,
            failOnStatusCode: false,
          }).then((portalResp) => {
            if (portalResp.status !== 200) {
              cy.log("portal branding not reachable; only the hub's own is asserted");
              return;
            }
            expect(
              String(hubResp.body),
              "a hub with its own branding_source must not be served the portal assets",
            ).to.not.eq(String(portalResp.body));
          });
        },
      );
    });
  });
});
