// Shared, data-robust assertions for the smoke suite. Kept intentionally tolerant: they
// judge "the deployment serves a working page/API", not specific demo content.
import { hasService } from "./services";

// Framework/server error markers — the same signals Gatus body-patterns look for.
const SERVER_ERROR_MARKERS = [
  "HTTP Status 500",
  "Application error",
  "An error has occurred",
  "Whitelabel Error Page",
  "grails.gsp",
];

/** Assert an HTTP endpoint answers without a server error (status < 400). */
export function apiOk(url: string): void {
  cy.request({ url, failOnStatusCode: false }).then((resp) => {
    expect(resp.status, `GET ${url}`).to.be.lessThan(400);
  });
}

/** Assert the current page rendered a real body and shows no server-error markers. */
export function pageRenders(): void {
  cy.get("body", { timeout: 20000 }).should("be.visible");
  cy.document().then((doc) => {
    const text = doc.body.innerText || "";
    SERVER_ERROR_MARKERS.forEach((marker) => {
      expect(text, `page should not contain "${marker}"`).to.not.contain(marker);
    });
  });
}

/** Skip the enclosing spec if the service isn't present in this inventory's manifest. */
export function skipIfMissing(key: string, ctx: Mocha.Context): void {
  if (!hasService(key)) {
    ctx.skip();
  }
}
