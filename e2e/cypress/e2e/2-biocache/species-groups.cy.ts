import { serviceUrl } from "../../support/services";
import { apiOk, skipIfMissing } from "../../support/checks";

// Species groups and vernacular names both come from the name index at ingest time, not
// from bie at query time: pipelines asks namematching-service for a match and stores its
// speciesGroup and vernacularName in the occurrence index. Neither had any coverage, and
// both were silently wrong or unverified.
//
// groups.json maps each group onto taxon names that are resolved against that index, so a
// file written for one backbone misclassifies on another. On COL, ALA's `Osteichthyes`
// resolves to an unranked clade whose lft/rgt range contains Aves and Mammalia, so all
// 2072 birds of the CI dataset came back as Birds AND as Fishes while every check stayed
// green. scripts/validate-species-groups.sh checks the file itself; this spec checks the
// result the portal actually serves.
describe("Species groups and vernacular names", () => {
  before(function () {
    skipIfMissing("recordsWs", this);
  });

  it("explore/groups keeps the vertebrate classes disjoint", () => {
    const url = serviceUrl("recordsWs", "/explore/groups?q=*:*");
    apiOk(url);
    cy.request({ url, failOnStatusCode: false }).then((resp) => {
      const groups: { name: string; count: number }[] = resp.body;
      expect(groups, "explore/groups body").to.be.an("array");

      const countOf = (name: string) =>
        groups.find((g) => g.name === name)?.count ?? 0;
      const animals = countOf("Animals");

      // Nothing to assert on an empty index, which is a legitimate deployment.
      if (animals === 0) {
        cy.log("no animal records indexed — nothing to check");
        return;
      }

      // Mammals, Birds, Reptiles, Amphibians and Fishes are disjoint classes, so a record
      // belongs to at most one. Their sum exceeding the Animals total means some records
      // are being counted in two groups at once. Dataset-independent on purpose: it holds
      // for a demo of 2k birds and for a national portal of 50M records alike.
      const disjoint = ["Mammals", "Birds", "Reptiles", "Amphibians", "Fishes"];
      const perGroup = disjoint.map((n) => `${n}=${countOf(n)}`).join(" ");
      const sum = disjoint.reduce((acc, n) => acc + countOf(n), 0);
      expect(
        sum,
        `disjoint vertebrate groups sum to more than Animals=${animals} (${perGroup}) — ` +
          `a taxon in groups.json is resolving to a range that swallows another group`
      ).to.be.at.most(animals);
    });
  });

  it("occurrences carry a common name from the name index", () => {
    const url = serviceUrl(
      "recordsWs",
      "/occurrences/search?q=*:*&facets=common_name&flimit=5&pageSize=0"
    );
    apiOk(url);
    cy.request({ url, failOnStatusCode: false }).then((resp) => {
      if ((resp.body.totalRecords ?? 0) === 0) {
        cy.log("no records indexed — nothing to check");
        return;
      }
      // An index whose vernacular component is missing (or an index older than the 2023
      // format, which carries no preferred vernacular at all) answers 200 with an empty
      // facet. That is exactly the failure other LA nodes hit and mistook for a hub bug.
      const facet = (resp.body.facetResults ?? []).find(
        (f: { fieldName: string }) => f.fieldName === "common_name"
      );
      expect(
        facet?.fieldResult ?? [],
        "common_name facet is empty: the name index resolved no vernacular names"
      ).to.have.length.greaterThan(0);
    });
  });
});
