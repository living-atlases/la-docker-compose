module.exports = {
  isDevel: true,
  inMante: false, // set to true and deploy if you want to set a maintenance message in all the services
  enabledLangs: ['en', 'es', 'zh', 'sw'],
  mainDomain: 'l-a.site', // used for cookies (without http/https)
  mainLAUrl: 'https://l-a.site',
  baseFooterUrl: 'https://branding.l-a.site/brand-2023',
  theme: 'simplex',
  services: {
    collectory: { url: 'https://collections.l-a.site', title: 'Collections' },
    biocache: { url: 'https://records.l-a.site', title: 'Occurrence records' },
    biocacheService: { url: 'https://records-ws.l-a.site', title: 'Occurrence records webservice' },
    bie: { url: 'https://species.l-a.site', title: 'Species' },
    // This bieService var is used by the search autocomplete. With your BIE
    bieService: { url: 'https://species-ws.l-a.site', title: 'Species webservice' },
    regions: { url: 'https://regions.l-a.site', title: 'Regions' },
    lists: { url: 'https://lists.l-a.site', title: 'Species List' },
    spatial: { url: 'https://spatial.l-a.site', title: 'Spatial Portal' },
    images: { url: 'https://images.l-a.site', title: 'Images Service' },
    cas: { url: 'https://auth.l-a.site', title: 'CAS' }
  },
  otherLinks: [
    { title: 'Datasets', url: 'https://collections.l-a.site/datasets' },
    { title: 'Explore your area', url: 'https://records.l-a.site/explore/your-area/' },
    { title: 'twitter', url: '', icon: 'twitter' }
  ]
}
