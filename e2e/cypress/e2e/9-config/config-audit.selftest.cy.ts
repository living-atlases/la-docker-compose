import {
  auditEffectiveConfig,
  isConfigProperty,
  isSecretShaped,
  parseConfigTable,
  safeUrl,
  urlHost,
  type DeclaredFallback,
} from "../../support/config-audit";

// Self-test for the effective-config audit. Runs offline: no stack, no login, no network, so
// it executes on every build regardless of ENABLE_AUTH_TESTS and regardless of whether the
// deployment is up.
//
// It exists because of a specific, expensive lesson: two "guards" were merged that passed
// happily over the very file that had broken the build. A check nobody has watched fail is
// not a check. These assertions pin both directions — the drifted fixture MUST produce
// exactly the known findings, and the clean fixture MUST produce none — so any future edit
// to config-audit.ts that softens the rules turns this red instead of turning the live spec
// silently green.

const OWN_HOSTS = [
  "l-a.site",
  "auth.l-a.site",
  "collections.l-a.site",
  "records-ws.l-a.site",
  "species.l-a.site",
  "species-ws.l-a.site",
  "images.l-a.site",
  "lists.l-a.site",
  "logger.l-a.site",
];

// Mirrors one entry of the seeded ala_upstream_fallbacks list, property-scoped.
const FALLBACKS: DeclaredFallback[] = [
  {
    host: "spatial.ala.org.au",
    property: "spatial.tileUrl",
    reason: "no alternative OSM tile server available to us",
  },
];

function loadFixture(name: string): Cypress.Chainable<Record<string, string>> {
  return cy.fixture(`viewconfig/${name}`).then((html: string) => {
    const doc = new DOMParser().parseFromString(html, "text/html");
    return parseConfigTable(doc);
  });
}

describe("Effective-config audit (offline self-test)", () => {
  describe("key classification", () => {
    it("keeps dotted lower-case config properties", () => {
      expect(isConfigProperty("security.apikey.auth.serviceUrl")).to.be.true;
      expect(isConfigProperty("userDetails.url")).to.be.true;
      expect(isConfigProperty("rifcs.excludeBounds")).to.be.true;
    });

    it("drops the process environment, which viewConfig merges into the config", () => {
      // The whole reason this filter exists: /alaAdmin/viewConfig is the flattened
      // grailsApplication.config, and the process environment is in there.
      ["JAVA_OPTS", "PATH", "HOME", "PWD", "LANG", "CATALINA_BASE", "INVOCATION_ID"].forEach(
        (k) => expect(isConfigProperty(k), k).to.be.false,
      );
      expect(isConfigProperty("SPRING_ELASTICSEARCH_URIS")).to.be.false;
    });

    it("drops JVM system properties, which are dotted and lower-cased like real config", () => {
      ["java.vendor.url", "user.home", "os.name", "file.encoding", "sun.boot.library.path"].forEach(
        (k) => expect(isConfigProperty(k), k).to.be.false,
      );
    });

    it("recognises secret-shaped keys", () => {
      expect(isSecretShaped("webservice.apiKey")).to.be.true;
      expect(isSecretShaped("security.apikey.auth.serviceUrl")).to.be.true;
      expect(isSecretShaped("collectory.baseUrl")).to.be.false;
    });
  });

  describe("URL handling", () => {
    it("extracts hosts only from absolute http(s) URLs", () => {
      expect(urlHost("https://auth.ala.org.au/x")).to.eq("auth.ala.org.au");
      expect(urlHost("la_solr:8983")).to.be.null;
      expect(urlHost("true")).to.be.null;
      expect(urlHost("")).to.be.null;
    });

    it("strips credentials and query strings from every reported value", () => {
      expect(safeUrl("https://u:p@auth.ala.org.au/apikey/?apiKey=abc#f")).to.eq(
        "https://auth.ala.org.au/apikey/",
      );
    });
  });

  describe("a drifted deployment", () => {
    it("flags exactly the four known-bad references, and nothing else", () => {
      loadFixture("drifted.html").then((props) => {
        const r = auditEffectiveConfig({
          props,
          ownHosts: OWN_HOSTS,
          declaredFallbacks: FALLBACKS,
        });
        const keys = r.findings.map((f) => f.key).sort();
        expect(keys, JSON.stringify(r.findings, null, 2)).to.deep.eq([
          "biocacheService.baseUrl", // ALA's records service, which we deploy ourselves
          "events.graphql", // ALA test infrastructure
          "security.apikey.auth.serviceUrl", // the gbif.es production defect, case-variant
          "userDetails.url", // the data-quality defect
        ]);
      });
    });

    it("does not flag the environment, the JVM properties, the docs link or the fallback", () => {
      loadFixture("drifted.html").then((props) => {
        const r = auditEffectiveConfig({
          props,
          ownHosts: OWN_HOSTS,
          declaredFallbacks: FALLBACKS,
        });
        const flagged = r.findings.map((f) => f.key);
        ["JAVA_OPTS", "SPRING_ELASTICSEARCH_URIS", "java.vendor.url", "user.home"].forEach((k) =>
          expect(flagged, `${k} must not be a finding`).to.not.include(k),
        );
        expect(flagged).to.not.include("dataquality.learnmore_link");
        expect(flagged).to.not.include("spatial.tileUrl");
      });
    });

    it("reports the declared fallback as informational, carrying its reason", () => {
      loadFixture("drifted.html").then((props) => {
        const r = auditEffectiveConfig({
          props,
          ownHosts: OWN_HOSTS,
          declaredFallbacks: FALLBACKS,
        });
        const tile = r.informational.find((i) => i.key === "spatial.tileUrl");
        expect(tile, "declared fallback must still be visible").to.exist;
        expect(tile!.reason).to.contain("declared:");
        expect(tile!.reason).to.contain("OSM tile server");
        expect(r.staleFallbacks, "the fallback was used, so it is not stale").to.be.empty;
      });
    });

    it("would flag the fallback if it were not declared — the exemption is what silences it", () => {
      loadFixture("drifted.html").then((props) => {
        const r = auditEffectiveConfig({ props, ownHosts: OWN_HOSTS, declaredFallbacks: [] });
        expect(r.findings.map((f) => f.key)).to.include("spatial.tileUrl");
      });
    });

    it("scopes a property-scoped fallback to that property only", () => {
      // Same host under a different key must NOT inherit the exemption: spatial.ala.org.au is
      // an accepted tile source, not an accepted spatial portal.
      const r = auditEffectiveConfig({
        props: { "spatial.baseUrl": "https://spatial.ala.org.au/" },
        ownHosts: OWN_HOSTS,
        declaredFallbacks: FALLBACKS,
      });
      expect(r.findings.map((f) => f.key)).to.deep.eq(["spatial.baseUrl"]);
    });
  });

  describe("a correctly configured deployment", () => {
    it("produces no findings", () => {
      loadFixture("clean.html").then((props) => {
        const r = auditEffectiveConfig({ props, ownHosts: OWN_HOSTS, declaredFallbacks: [] });
        expect(r.findings, JSON.stringify(r.findings, null, 2)).to.be.empty;
      });
    });

    it("still surfaces the ALA documentation links as informational", () => {
      loadFixture("clean.html").then((props) => {
        const r = auditEffectiveConfig({ props, ownHosts: OWN_HOSTS, declaredFallbacks: [] });
        const keys = r.informational.map((i) => i.key).sort();
        expect(keys).to.deep.eq(["dataquality.learnmore_link", "skin.exploreUrl"]);
      });
    });

    it("keeps secrets out of the URL map that seeds the layer-5 baseline", () => {
      loadFixture("clean.html").then((props) => {
        const r = auditEffectiveConfig({ props, ownHosts: OWN_HOSTS, declaredFallbacks: [] });
        // URL-valued and secret-shaped: the case where the exclusion actually has to work.
        expect(props["security.oidc.tokenEndpoint"], "fixture sanity").to.contain("https://");
        expect(Object.keys(r.urlMap)).to.not.include("security.oidc.tokenEndpoint");
        expect(Object.keys(r.urlMap)).to.not.include("webservice.apiKey");
        expect(Object.keys(r.urlMap)).to.not.include("security.apikey.secret");
        expect(r.urlMap["collectory.baseUrl"]).to.eq("https://collections.l-a.site/");
      });
    });

    it("keeps JVM system properties out of the URL map, so the baseline does not churn", () => {
      // java.vendor.url is never a finding (oracle.com is not ALA), but it would pollute the
      // frozen layer-5 baseline and make it move on every JVM upgrade. This is the assertion
      // that makes SYSTEM_NAMESPACES load-bearing rather than decorative.
      loadFixture("clean.html").then((props) => {
        const r = auditEffectiveConfig({ props, ownHosts: OWN_HOSTS, declaredFallbacks: [] });
        expect(Object.keys(r.urlMap)).to.not.include("java.vendor.url");
        expect(Object.keys(r.urlMap)).to.not.include("java.vendor.url.bug");
      });
    });

    it("reports a fallback that matched nothing, so the list cannot rot", () => {
      loadFixture("clean.html").then((props) => {
        const r = auditEffectiveConfig({
          props,
          ownHosts: OWN_HOSTS,
          declaredFallbacks: FALLBACKS,
        });
        expect(r.staleFallbacks.map((f) => f.host)).to.deep.eq(["spatial.ala.org.au"]);
      });
    });
  });

  describe("the parser itself", () => {
    it("reads the two-cell rows and ignores the header", () => {
      loadFixture("clean.html").then((props) => {
        // Guards against the parser silently returning {} after an upstream restyle, which
        // would make the live spec report zero findings and look green.
        expect(Object.keys(props).length).to.be.greaterThan(20);
        expect(props["collectory.baseUrl"]).to.eq("https://collections.l-a.site");
        expect(props).to.not.have.property("Property");
      });
    });
  });
});
