// Inspired by & adapted from inbo/vlaams-biodiversiteitsportaal (MPL-2.0):
//   https://github.com/inbo/vlaams-biodiversiteitsportaal
// Specifically test/cypress/e2e/5-species-list/manage.cy.ts, which drives the same
// specieslist-webapp Upload form (both are Living Atlases deployments running the same
// upstream service, so the same form/element ids apply). Adapted:
//   - cy.loginTo("lists") (this repo's CAS/OIDC multi-hub login) instead of Flanders'
//     Keycloak-specific cy.login("species-list").
//   - Creates ONE list with a STABLE name and skips creation if it already exists, instead
//     of Flanders' timestamped name + always-create + always-delete pair of specs. This
//     spec exists to seed data a Gatus health check depends on staying present (see below),
//     so it deliberately does NOT delete what it creates.
import { serviceUrl } from "../../support/services";
import { mutationTestsEnabled, skipIfMissing } from "../../support/checks";
import { getTestOccurrenceCsv, TEST_LIST_NAME, TEST_LIST_SCIENTIFIC_NAME } from "../../support/lists";

// Closes Gatus's "lists count" Data check (roles/la-compose/vars/gatus-extra-endpoints.yml),
// which asserts `[BODY].listCount > 0` on the lists service and is red on any deployment that
// has never had a list created through the UI -- a legitimate state nothing else in the
// deploy chain changes (see e2e/cypress/e2e/6-lists/load.cy.ts, the read-only shape check).
//
// Gated behind CYPRESS_ENABLE_MUTATION_TESTS: creating a real list through the live UI is not
// something every smoke run should do. The CI sets this only when it wants the "lists count"
// check (and the rest of Gatus's "Data checks" group) to gate the build -- see the
// Jenkinsfile's RUN_LISTS_SEED param and scripts/verify-deployment.sh --gate-data-checks.
describe("Species list - manage (mutation)", () => {
  before(function () {
    skipIfMissing("lists", this);
    if (!mutationTestsEnabled()) {
      this.skip();
    }
  });

  beforeEach(() => {
    // The ALA Grails admin/list views load Bootstrap's JS before jQuery. Matched narrowly so
    // a genuine application error on the upload flow still fails the test.
    cy.on("uncaught:exception", (err) => {
      const jqueryMissing =
        /(^|\s)(jQuery|\$) is not defined/.test(err.message) ||
        /Bootstrap's JavaScript requires jQuery/.test(err.message);
      return !jqueryMissing;
    });
  });

  it("creates a species list through the Upload UI, unless one already exists", () => {
    cy.loginTo("lists");

    // Idempotent: a stable list name means a re-run finds its own earlier list and leaves it
    // alone, instead of piling up a new one per build.
    cy.request(serviceUrl("lists", "/ws/speciesList?max=1000")).then((resp) => {
      const already = (resp.body?.lists ?? []).some(
        (l: { listName?: string }) => l.listName === TEST_LIST_NAME,
      );
      if (already) {
        cy.log(`"${TEST_LIST_NAME}" already exists; not creating a duplicate.`);
        return;
      }

      cy.visit(serviceUrl("lists", "/"));
      cy.get("a").contains("Upload").click();

      cy.get("#copyPasteData").type(getTestOccurrenceCsv(TEST_LIST_SCIENTIFIC_NAME), {
        parseSpecialCharSequences: false,
      });
      cy.get("#checkData").click();
      cy.get("#initialParse")
        .find("tbody > tr")
        .should("have.length", 1)
        .should("contain", TEST_LIST_SCIENTIFIC_NAME);

      cy.get("#listTitle").type(TEST_LIST_NAME);
      // The list-type dropdown's option labels are deployment-specific (Flanders' fork
      // localizes them, e.g. "Test lijst"). Picking the first real option keeps this
      // deployment-agnostic; verify against the live UI if this deployment requires a
      // specific type.
      cy.get("#listTypeId").find("option").eq(1).then(($opt) => {
        cy.get("#listTypeId").select($opt.val() as string);
      });
      cy.get("#uploadButton").click();

      cy.get(".subject-subtitle").should("contain", TEST_LIST_NAME);
      cy.get("#listView")
        .find("tbody > tr")
        .should("have.length", 1)
        .should("contain", TEST_LIST_SCIENTIFIC_NAME);
    });
  });

  it("lists webservice now reports at least one list", () => {
    cy.request(serviceUrl("lists", "/ws/speciesList")).then((resp) => {
      expect(resp.body?.listCount, "listCount after seeding").to.be.greaterThan(0);
    });
  });
});

// Manual/local hygiene only -- NOT wired into any CI param. Deleting the seeded list would
// immediately flip Gatus's "lists count" check back to red, which is the opposite of what
// the mutation spec above exists to do. Run by hand with CYPRESS_CLEANUP_TEST_LISTS=true
// against a throwaway dev stack when the seeded list is no longer wanted.
describe("Species list - cleanup (manual only)", () => {
  before(function () {
    skipIfMissing("lists", this);
    if (String(Cypress.env("CLEANUP_TEST_LISTS")) !== "true") {
      this.skip();
    }
  });

  it(`deletes every list named "${TEST_LIST_NAME}"`, () => {
    cy.loginTo("lists");
    cy.visit(serviceUrl("lists", "/myLists"));
    cy.get("body").then(($body) => {
      const rows = $body.find(`a:contains("${TEST_LIST_NAME}")`);
      if (rows.length === 0) {
        cy.log("nothing to clean up");
        return;
      }
      cy.wrap(rows).each(($row) => {
        cy.wrap($row).parents("tr").find("a").contains(/delete/i).click();
        cy.get("body").then(($confirmBody) => {
          const confirm = $confirmBody.find('input[type="submit"], button').filter((_, el) => {
            const value = "value" in el ? String((el as { value?: unknown }).value ?? "") : "";
            return /ok|confirm|yes/i.test(el.textContent || value);
          });
          if (confirm.length) {
            cy.wrap(confirm.first()).click();
          }
        });
      });
    });
  });
});
