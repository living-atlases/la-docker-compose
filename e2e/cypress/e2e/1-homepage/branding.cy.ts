import { hasService, rootUrl, serviceUrl } from "../../support/services";
import { linkedAssetsLoad, pageRenders } from "../../support/checks";

// The homepage is the canary for branding: ALA hubs fetch header/footer from the branding
// service at boot and cache it. If branding served null, pages render blank/500 (a recurring
// failure mode in this deployment). This spec fails loudly when that happens.
describe("Homepage / branding", () => {
  it("root page loads and renders branded chrome", () => {
    cy.visit(rootUrl("/"));
    pageRenders();

    // A non-empty <title> and a real header/masthead → branding actually rendered.
    cy.title().should("not.be.empty");
    cy.get("header, .navbar, #header, [class*='header'], [class*='masthead']").should(
      "exist",
    );
    // Some visible body text (not a blank page).
    cy.get("body").invoke("text").its("length").should("be.greaterThan", 50);
  });

  // The UIs that take their chrome from the branding: a 200 page with every CSS/JS 404
  // renders bare HTML and passes every other check here.
  it("root page: every stylesheet and script it links loads", () => {
    linkedAssetsLoad(rootUrl("/"));
  });

  ["records", "species", "regions", "collections", "lists"].forEach((ui) => {
    it(`${ui}: every stylesheet and script it links loads`, function () {
      if (!hasService(ui)) {
        this.skip();
      }
      linkedAssetsLoad(serviceUrl(ui, "/"));
    });
  });
});
