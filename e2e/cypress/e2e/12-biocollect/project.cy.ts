import { serviceUrl } from "../../support/services";
import { authTestsEnabled, skipIfMissing } from "../../support/checks";

// The home page only proves biocollect can read from ecodata. Writing is what needs the CAS
// login, the ecodata/write scope and biocollect's address on the ecodata-api network, so a
// project is created the way the app's own form does it, and read back.
//
// Leaves the project behind: the name is new on every run, and CI wipes the stack anyway.
describe("BioCollect project and PDF", () => {
  before(function () {
    skipIfMissing("biocollect", this);
    if (!authTestsEnabled()) {
      this.skip();
    }
  });

  it("logs in through CAS and stores a project in ecodata", () => {
    // /project/create sends an anonymous visitor away, so it validates the cached session.
    cy.loginTo("biocollect", "/project/create");

    const name = `e2e project ${Date.now()}`;
    cy.request({
      method: "POST",
      url: serviceUrl("biocollect", "/project/ajaxCreate"),
      body: { name, description: name, projectType: "survey", isCitizenScience: true },
      failOnStatusCode: false,
    }).then((created) => {
      expect(created.status, "POST /project/ajaxCreate").to.eq(200);
      expect(created.body, "ajaxCreate body").to.have.property("projectId");

      cy.request(serviceUrl("biocollect", `/project/index/${created.body.projectId}`))
        .its("body")
        .should("contain", name);
    });
  });

  it("generates a PDF through pdfgen", () => {
    cy.loginTo("biocollect", "/project/create");

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
