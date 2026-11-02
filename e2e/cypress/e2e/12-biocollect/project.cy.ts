import { serviceUrl } from "../../support/services";
import { authTestsEnabled, skipIfMissing } from "../../support/checks";

// The home page only proves biocollect can read from ecodata. Writing is what needs the CAS
// login, the ecodata/write scope and biocollect's address on the ecodata-api network, so a
// project is created through the app's own endpoints, and read back.
//
// Leaves its data behind: the names are new on every run, and CI wipes the stack anyway.
describe("BioCollect project and PDF", () => {
  before(function () {
    skipIfMissing("biocollect", this);
  });

  it("logs in through CAS and stores a project in ecodata", function () {
    if (!authTestsEnabled()) {
      this.skip();
    }
    // /project/create sends an anonymous visitor away, so it validates the cached session.
    cy.loginTo("biocollect", "/project/create");

    const name = `e2e ${Date.now()}`;
    cy.request({
      method: "POST",
      url: serviceUrl("biocollect", "/organisation/ajaxUpdate"),
      body: { name, description: name },
      failOnStatusCode: false,
    }).then((org) => {
      expect(org.status, "POST /organisation/ajaxUpdate").to.eq(200);
      expect(org.body, "ajaxUpdate body").to.have.property("organisationId");

      cy.request({
        method: "POST",
        url: serviceUrl("biocollect", "/project/ajaxCreate"),
        // ecoScience with isExternal is the type that needs neither a site nor a task.
        body: {
          name,
          description: name,
          aim: name,
          projectType: "ecoScience",
          isExternal: true,
          organisationId: org.body.organisationId,
          plannedStartDate: new Date().toISOString(),
        },
        failOnStatusCode: false,
      }).then((created) => {
        expect(created.status, "POST /project/ajaxCreate").to.eq(200);
        expect(created.body, "ajaxCreate body").to.have.property("projectId");

        cy.request(serviceUrl("biocollect", `/project/index/${created.body.projectId}`))
          .its("body")
          .should("contain", name);
      });
    });
  });

  it("generates a PDF through pdfgen", () => {
    const file = encodeURIComponent(serviceUrl("biocollect", "/"));
    cy.request({
      url: serviceUrl("biocollect", `/resource/pdfUrl?file=${file}`),
      failOnStatusCode: false,
      timeout: 120000,
    }).then((resp) => {
      expect(resp.status, "GET /resource/pdfUrl").to.eq(200);
      // pdfgen redirects to the generated file. A failure leaves the request's own URL here,
      // with docUrl still on it, so the 200 alone proves nothing.
      expect(resp.body.location, "generated PDF location").to.match(/\/api\/pdf\/[^?]+$/);
    });
  });
});
