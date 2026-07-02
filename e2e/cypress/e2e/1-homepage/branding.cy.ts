import { rootUrl } from "../../support/services";
import { pageRenders } from "../../support/checks";

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
});
