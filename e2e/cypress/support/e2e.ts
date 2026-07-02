import "./commands";

// Living Atlas hubs occasionally raise benign client-side exceptions (jQuery/autocomplete
// timing, Leaflet/third-party map libs) that are unrelated to whether the deployment is
// correct. Don't let one of those abort a spec before our explicit content assertions run
// — the assertions (header present, results > 0, no error text) are what actually judge the
// page. Pattern borrowed from vlaams. Real breakage still shows up in those assertions.
Cypress.on("uncaught:exception", () => false);
