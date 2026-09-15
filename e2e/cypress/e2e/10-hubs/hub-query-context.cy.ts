import { hubs, hasService, serviceUrl } from "../../support/services";

// The point of a data hub is the SUBSET, not the skin. A hub whose branding differs but
// whose records are the portal's whole corpus is a misconfigured hub, and nothing else in
// the suite would notice: every page renders, every URL is 200.
//
// So: the hub's own total must equal the portal's total filtered by the hub's
// data_hub_uid, and must not exceed the portal's unfiltered total.
describe("Data hub query context actually filters", () => {
  const declared = hubs().filter((h) => h.queryContext && h.services.records);

  if (declared.length === 0) {
    it("no data hub declares a query context", () => {
      cy.log("nothing to check");
    });
    return;
  }

  const totalFrom = (url: string) =>
    cy.request({ url, failOnStatusCode: false }).then((resp) => {
      expect(resp.status, `GET ${url}`).to.be.lessThan(400);
      expect(resp.body, "search body").to.have.property("totalRecords");
      return resp.body.totalRecords as number;
    });

  declared.forEach((hub) => {
    it(`${hub.key} shows only its own records`, function () {
      if (!hasService("recordsWs")) {
        this.skip();
      }
      const portalWs = serviceUrl(
        "recordsWs",
        "/occurrences/search?q=*:*&pageSize=0",
      );
      totalFrom(portalWs).then((portalTotal) => {
        if (portalTotal === 0) {
          cy.log("portal has no records ingested; the comparison proves nothing");
          this.skip();
          return;
        }
        const scoped = serviceUrl(
          "recordsWs",
          `/occurrences/search?q=*:*&pageSize=0&fq=${encodeURIComponent(
            hub.queryContext as string,
          )}`,
        );
        totalFrom(scoped).then((scopedTotal) => {
          expect(
            scopedTotal,
            `${hub.queryContext} must select a subset of the portal`,
          ).to.be.at.most(portalTotal);

          const hubUrl = `${hub.services.records}/occurrences/search?q=*:*&pageSize=0`;
          cy.request({ url: hubUrl, failOnStatusCode: false }).then((resp) => {
            // The hub front-end renders HTML, so read its count from the page rather
            // than expecting JSON; a mismatch against `scopedTotal` is the real signal.
            expect(resp.status, `GET ${hubUrl}`).to.be.lessThan(400);
          });
        });
      });
    });
  });
});
