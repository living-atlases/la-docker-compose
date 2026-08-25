// Shared, data-robust assertions for the smoke suite. Kept intentionally tolerant: they
// judge "the deployment serves a working page/API", not specific demo content.
import { hasService } from "./services";

// Framework/server error markers. These MUST mirror `gatus_html_error_markers` in
// roles/la-compose/vars/gatus-extra-endpoints.yml, which expands them into
// `[BODY] != pat(*marker*)` conditions for every check marked `html: true`.
//
// The two lists had drifted: gatus only looked for "Application error" on the species hub,
// while the ALA Grails hubs actually render "An error has occurred". That is why this suite
// caught a broken bie-index -> Solr link and gatus reported the whole Deep checks group
// green. Add a marker here and there, or neither.
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

/**
 * True when the gated authentication specs are enabled (CYPRESS_ENABLE_AUTH_TESTS=true).
 *
 * Compare stringified: Cypress auto-imports CYPRESS_-prefixed environment variables and
 * COERCES them, so `Cypress.env("ENABLE_AUTH_TESTS")` is the boolean `true`, not the string
 * `"true"`. A bare `!== "true"` check therefore skips the spec even when the flag is on.
 */
export function authTestsEnabled(): boolean {
  return String(Cypress.env("ENABLE_AUTH_TESTS")) === "true";
}

/**
 * True when the deployment under test is expected to hold taxonomy in the bie index
 * (CYPRESS_BIE_HAS_DATA=true), which the CI sets only after scripts/e2e-bie-import.sh ran.
 *
 * The bie index is empty on a plain deploy and that is a legitimate deployment, so the
 * count assertion cannot be unconditional. It cannot be dropped either: on an empty index
 * `GET species-ws/search?q=Acacia` answers 200 with `totalRecords: 0`, which satisfies
 * `apiOk` and satisfied the matching gatus check too -- the whole species suite was green
 * over an index with no taxa in it. See living-atlases/la-toolkit#28.
 *
 * Stringified for the same reason as authTestsEnabled(): Cypress coerces CYPRESS_-prefixed
 * env vars, so a bare `!== "true"` never matches.
 */
export function bieHasData(): boolean {
  return String(Cypress.env("BIE_HAS_DATA")) === "true";
}

/** Skip the enclosing spec if the service isn't present in this inventory's manifest. */
export function skipIfMissing(key: string, ctx: Mocha.Context): void {
  if (!hasService(key)) {
    ctx.skip();
  }
}
