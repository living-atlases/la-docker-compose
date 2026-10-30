import { serviceUrl } from "../../support/services";
import { skipIfMissing } from "../../support/checks";

// BioCollect only exists in the topologies that enable it: skipIfMissing keeps the
// default build green. pdfgen has no public vhost, so it is proven through biocollect.
describe("BioCollect stack (biocollect, ecodata)", () => {
  it("ecodata answers through its vhost", function () {
    skipIfMissing("ecodata", this);
    cy.request({ url: serviceUrl("ecodata", "/"), failOnStatusCode: false }).then((resp) => {
      expect(resp.status, "ecodata /").to.be.lessThan(500);
    });
  });

  it("biocollect renders its home page, which reads from ecodata", function () {
    skipIfMissing("biocollect", this);
    cy.request({ url: serviceUrl("biocollect", "/"), failOnStatusCode: false }).then((resp) => {
      expect(resp.status, "biocollect /").to.be.lessThan(500);
    });
  });
});
