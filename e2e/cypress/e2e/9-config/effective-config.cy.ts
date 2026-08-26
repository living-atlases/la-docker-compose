import {
  declaredAlaFallbacks,
  hasService,
  ownHosts,
  serviceUrl,
  type AlaUpstreamFallback,
} from "../../support/services";
import { authTestsEnabled } from "../../support/checks";
import {
  auditEffectiveConfig,
  formatEntries,
  parseConfigTable,
} from "../../support/config-audit";

// Layer 3 of config validation: what the application ACTUALLY resolved, not what we rendered.
//
// A properties diff can only compare keys that exist in a file. Grails applies a compiled-in
// default for every key ala-install does not parameterise, and those defaults point at ALA.
// The resulting value is in no file, no inventory and no diff — only in the running process.
// gbif.es production shipped for months with collectory resolving
// security.apikey.auth.serviceUrl to https://auth-test.ala.org.au/apikey/ for exactly that
// reason. This spec reads the running config and audits it.
//
// GATED like 8-auth: /alaAdmin/viewConfig needs a ROLE_ADMIN session, so it runs only with
// CYPRESS_ENABLE_AUTH_TESTS=true. The classification logic itself is covered unconditionally
// and offline by config-audit.selftest.cy.ts, so a build with auth tests off still verifies
// the rules; what it cannot verify is the live values.

// Services confirmed to expose the page in this stack. `lists` answers 403 with no redirect
// (species-list-webapp does not carry the ala-admin plugin), so it is left out rather than
// skipped at runtime — an empty result there would be indistinguishable from "no findings".
const AUDITED = ["collections", "species", "regions", "records"] as const;

// Aggregated across services: a fallback is stale only if NO service uses it. Per-service
// staleness is meaningless — the pdfgen fallback lives in ala-hub and is legitimately absent
// from collectory.
const usedFallbacks = new Set<string>();
const auditedServices: string[] = [];

function fallbackId(f: AlaUpstreamFallback): string {
  return `${f.host}|${f.property ?? "*"}`;
}

describe("Effective configuration (/alaAdmin/viewConfig)", () => {
  before(function () {
    if (!authTestsEnabled()) {
      this.skip();
    }
  });

  // These pages load Bootstrap's JS before jQuery, so they throw
  // "ReferenceError: jQuery is not defined" (and its "$ is not defined" sibling) on load,
  // and Cypress fails the test on any uncaught application exception. That is a real, if
  // cosmetic, upstream defect in the ala-admin/CAS views; it is not what this spec measures,
  // because the property table is server-rendered and complete regardless of whether the
  // page's JavaScript ran.
  //
  // Matched narrowly on purpose. A blanket `return false` would also swallow a genuine
  // application error on the config page and let the audit report "no findings" over a broken
  // service -- the same hollow-green shape this spec exists to prevent.
  Cypress.on("uncaught:exception", (err) => {
    const jqueryMissing =
      /(^|\s)(jQuery|\$) is not defined/.test(err.message) ||
      /Bootstrap's JavaScript requires jQuery/.test(err.message);
    return !jqueryMissing;
  });

  AUDITED.forEach((key) => {
    it(`${key}: effective config points at this deployment, not at ALA`, function () {
      if (!hasService(key)) {
        this.skip();
      }
      // Per-hub login, not cy.login(): the CAS ticket-granting cookie does not survive
      // cy.session, so a records-hub session gives no SSO on collections/species/regions and
      // every visit here would land on the CAS login form. See loginTo in support/commands.ts.
      cy.loginTo(key);

      // Fetch rather than visit. The admin GSP loads Bootstrap's JS before jQuery and throws
      // on load; Cypress fails a test on any uncaught application exception, and neither
      // Cypress.on in this spec nor cy.on inside the session callbacks suppresses it. The
      // config table is server-rendered, so a request gets the identical data with none of
      // the page's broken JavaScript in the way -- and it parses through exactly the same
      // parseConfigTable() the offline self-test exercises.
      cy.request({
        url: serviceUrl(key, "/alaAdmin/viewConfig"),
        failOnStatusCode: false,
      }).then((resp) => {
        const html = String(resp.body || "");
        expect(resp.status, `GET ${key}/alaAdmin/viewConfig`).to.eq(200);

        // A 200 is not enough: unauthenticated, this endpoint follows the redirect chain and
        // answers 200 with the CAS login page, which parses to zero properties, produces zero
        // findings and reports green. That is the exact hollow-check shape this whole
        // workstream exists to stop, so the login page is rejected explicitly.
        const title = (html.match(/<title>([^<]*)</) || [])[1] || "";
        expect(title, `${key}: served the CAS login page, so the session was not applied`).to
          .not.match(/login/i);

        const doc = new DOMParser().parseFromString(html, "text/html");
        const props = parseConfigTable(doc);
        expect(
          Object.keys(props).length,
          `${key}: parsed properties from /alaAdmin/viewConfig (0 means the page did not ` +
            `render the config table -- not that the config is clean)`,
        ).to.be.greaterThan(20);

        const result = auditEffectiveConfig({
          props,
          ownHosts: ownHosts(),
          declaredFallbacks: declaredAlaFallbacks(),
        });

        auditedServices.push(key);
        declaredAlaFallbacks().forEach((f) => {
          if (!result.staleFallbacks.includes(f)) usedFallbacks.add(fallbackId(f));
        });

        // Informational is not a failure, but it must be visible: the point of the exercise
        // is that a dependency on ALA is a decision somebody took, not a line nobody reads.
        if (result.informational.length) {
          cy.log(`${key}: ${result.informational.length} ALA reference(s), accepted`);
          // eslint-disable-next-line no-console
          console.log(
            `\n[${key}] accepted ALA references:\n${formatEntries(result.informational)}`,
          );
        }

        // One assertion carrying the whole list. Failing per-property would report the first
        // problem and hide the rest, which turns one fix-and-rerun cycle into five.
        expect(
          result.findings,
          `${key}: undeclared references to ALA infrastructure in the EFFECTIVE config.\n` +
            `${formatEntries(result.findings)}\n` +
            `Each is either a bug to fix in the ala-install role / la-compose template, or a ` +
            `deliberate dependency to declare in ala_upstream_fallbacks with a reason ` +
            `(roles/la-compose/defaults/main.yml).\n`,
        ).to.have.length(0);

        // Seed for the layer-5 baseline. URL-valued, non-secret keys only, credentials and
        // query strings stripped by safeUrl -- safe by construction, not by review.
        cy.writeFile(
          `results/effective-config-${key}.json`,
          {
            service: key,
            url: serviceUrl(key, "/alaAdmin/viewConfig"),
            propertyCount: Object.keys(props).length,
            urls: result.urlMap,
            acceptedAlaReferences: result.informational,
          },
          { log: false },
        );
      });
    });
  });

  it("the declared ALA fallback list has not rotted", function () {
    // A fallback that no service resolves any more is a dependency somebody removed without
    // removing the exemption. Left alone, the list slowly becomes fiction and stops meaning
    // "these are our ALA dependencies". Reported, not fatal: the audited set is only four
    // services, and a fallback may legitimately live in one we cannot read.
    if (auditedServices.length === 0) {
      this.skip();
    }
    const stale = declaredAlaFallbacks().filter((f) => !usedFallbacks.has(fallbackId(f)));
    if (stale.length) {
      const lines = stale.map((f) => `  ${f.host} (${f.property ?? "any key"}) -- ${f.reason}`);
      cy.log(`${stale.length} declared fallback(s) matched nothing`);
      // eslint-disable-next-line no-console
      console.log(
        `\nDeclared ALA fallbacks not seen in ${auditedServices.join(", ")}:\n` +
          `${lines.join("\n")}\n` +
          `If the dependency is gone, drop the entry from ala_upstream_fallbacks.\n`,
      );
    }
  });
});
