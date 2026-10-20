import { authUrl, serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Species lists.
describe("Species lists", () => {
  before(function () {
    skipIfMissing("lists", this);
  });

  it("species-list ws responds", () => {
    apiOk(serviceUrl("lists", "/ws/speciesList"));
  });

  it("lists home renders", () => {
    cy.visit(serviceUrl("lists", "/"));
    pageRenders();
    cy.get("body").invoke("text").its("length").should("be.greaterThan", 50);
  });

  // Since specieslist-webapp 4.0.0 (ala-auth pac4j) security.cas.uriFilterPattern is a list of
  // servlet url-patterns ('/admin', '/admin/*'). ala-install used to render the regex '/admin.*',
  // which matches no request: signed out, /admin then answered 302 to /public/speciesLists
  // instead of asking for a login, and Upload was open to anonymous users. A bare 302 check
  // passes on that bug, so assert where the redirect goes. A request, not a visit: following
  // the redirect destroys the evidence.
  ["/admin", "/speciesList/upload"].forEach((path) => {
    it(`${path} sends a signed-out user to the OIDC login`, () => {
      cy.request({
        url: serviceUrl("lists", path),
        followRedirect: false,
        failOnStatusCode: false,
      }).then((resp) => {
        expect(resp.status, `lists ${path} signed out`).to.eq(302);
        const location = String(resp.headers.location || "");
        expect(location, `lists ${path} redirect`).to.contain(new URL(authUrl()).host);
        expect(location, `lists ${path} redirect`).to.contain("oidcAuthorize");
      });
    });
  });
});
