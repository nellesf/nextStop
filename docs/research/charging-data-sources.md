# Free charging data source research

Research date: 2026-08-13; German and Swiss source evidence rechecked on 2026-08-15.
“Free/open” here is a technical screening, not legal advice. Re-check terms,
attribution, caching, and redistribution before enabling a provider.

## Regulatory and European access layer

EU Regulation 2023/1804 (AFIR), Article 20, requires operators to expose specified
static and dynamic charging data through free/unrestricted APIs and Member States
to make it accessible through National Access Points. It requires the European
Commission to establish CEAP by **2026-12-31**. The 2025 delegated/implementing
rules address common API, format, frequency, quality, and future CEAP scalability.

Primary sources:

- [AFIR consolidated text / Article 20](https://eur-lex.europa.eu/legal-content/en/ALL/?uri=CELEX%3A02023R1804-20260108)
- [Regulation (EU) 2023/1804](https://eur-lex.europa.eu/eli/reg/2023/1804/oj/eng)
- [Delegated Regulation (EU) 2025/645](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32025R0645)
- [Commission announcement of the 2025 interoperability rules](https://transport.ec.europa.eu/news-events/news/commission-enhances-interoperability-and-transparency-of-alternative-fuels-infrastructure-data-2025-04-11_en)
- [EU list of National Access Points](https://transport.ec.europa.eu/transport-themes/smart-mobility/road/its-directive-and-action-plan/national-access-points_en)
- [NAPCORE National Access Point directory](https://napcore.eu/description-naps/national-access-point/)

### CEAP status

No official production CEAP gateway/API was located on 2026-08-13. Official 2025
material still describes technical recommendations and a gateway to be established
by December 2026.

- [EU Publications: CEAP — From concept to implementation](https://op.europa.eu/en/publication-detail/-/publication/132a219e-f3f5-11ef-b7db-01aa75ed71a1/language-en)

Decision: implement national/official providers now and keep CEAP behind the same
provider interface. Validate it rather than switching automatically when a portal
appears.

## Screened provider sources

| Coverage | Source | Data/capability | Access/license findings | MVP position |
|---|---|---|---|---|
| EU | Country NAPs through AFIR/NAPCORE directory | Heterogeneous static/dynamic metadata/API catalogs | Statutory open access; protocols and operational quality vary | Discovery layer and country-by-country adapters |
| Germany | Bundesnetzagentur Ladesäulenregister | Authoritative static locations, EVSE/power data; downloadable CSV | Official public register; no useful live availability in the register | Recommended first ingestion; exercises unknown-live behavior |
| France | data.gouv.fr national IRVE base | Large consolidated static CSV/GeoJSON and APIs | Licence Ouverte / Open Licence | Early authority provider after vertical slice |
| Netherlands | NDW DOT-NL | AFIR charging data, locations and dynamic status; OCPI/DATEX/GeoJSON access evolves | Official NAP platform managed for the ministry; open-data downloads/API | High-priority live provider |
| Norway | NOBIL / Enova | Broad Norway/Sweden static and real-time data | Free registered API; CC BY 3.0 NO/NLOD references | High-priority non-EU provider |
| Switzerland | SFOE `ich-tanke-strom` / open transport data | Static JSON plus real-time availability | Official open API/catalog | Recommended second provider or first live slice |
| UK | National Charge Point Registry + operator OCPI feeds | Registry claims a real-time view; UK rules mandate OCPI reference and availability data | OGL; public machine-readable data free of charge | High-priority adapter; audit registry coverage vs operator endpoints |
| Europe/world | Open Charge Map | Supplemental community/aggregated locations | Free key; records have mixed licensing; `opendata=true` required for open-only results | Fallback/gap analysis, never silently mix non-open records |

## EU-27 discovery inventory

The Commission's October 2025 NAP inventory lists the following discovery portals.
These links establish the national access path; they do **not** by themselves prove
that an AFIR charging dataset/API is complete or production-ready. Each country
still needs the adapter audit described below.

| Member State | National discovery portal from the Commission inventory |
|---|---|
| Austria | <https://www.mobilitydata.gv.at/> |
| Belgium | <https://www.transportdata.be/en/> |
| Bulgaria | <https://www.mtitc.government.bg/en/category/294/national-access-points-transport-related-data> |
| Croatia | <https://www.promet-info.hr/> |
| Cyprus | <https://www.traffic4cyprus.org.cy/> |
| Czechia | <http://registr.dopravniinfo.cz/en/> |
| Denmark | <https://nap.vd.dk/> |
| Estonia | <https://tarktee.mnt.ee/> |
| Finland | <https://www.finap.fi/> / <https://www.digitraffic.fi/> |
| France | <https://transport.data.gouv.fr/> |
| Germany | <https://mobilithek.info/> |
| Greece | <https://www.nap.gov.gr/> |
| Hungary | <https://napportal.kozut.hu/> |
| Ireland | <https://data.gov.ie/> |
| Italy | <https://www.cciss.it/> |
| Latvia | <https://www.transportdata.gov.lv/> |
| Lithuania | <https://maps.eismoinfo.lt/> |
| Luxembourg | <https://data.public.lu/en/> |
| Malta | <https://geoservices.transport.gov.mt/egis> |
| Netherlands | <https://ntm.ndw.nu/> plus charging-specific DOT-NL |
| Poland | <https://dane.gov.pl/en/dataset/1739> |
| Portugal | <https://nap-portugal.imt-ip.pt/nap/home> |
| Romania | <https://pna.cestrin.ro/> |
| Slovakia | <https://www.zjazdnost.sk/> |
| Slovenia | National Traffic Management Centre NAP (see Commission inventory) |
| Spain | <https://nap.mitma.es/> / <https://nap.dgt.es/> |
| Sweden | <https://www.trafficdata.se/> |

Source: [European Commission ITS national-access-point inventory (October 2025 PDF)](https://transport.ec.europa.eu/document/download/963c997d-efd9-40ae-a38b-5d4b935bdfcf_en?filename=its-national-access-points.pdf).

For each country before implementation: locate the AFIR dataset/API, confirm EVSE
semantics and static/dynamic fields, test authentication/rate limits/pagination,
record license and attribution, measure freshness/completeness, and only then enable
the adapter. The inventory is a discovery mechanism, not a single harmonized feed.

### Primary source links

- Germany: [Bundesnetzagentur E-Mobilität and CSV](https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/start.html)
- France: [National IRVE dataset](https://www.data.gouv.fr/datasets/base-nationale-des-irve-infrastructures-de-recharge-pour-vehicules-electriques)
- Netherlands: [DOT-NL](https://english.ndw.nu/dataportals/dot-nl),
  [consumer API documentation](https://docs.ndw.nu/data-uitwisseling/interface-beschrijvingen/dafne-api/dafne_api_consumer_pull/)
- Norway: [NOBIL government catalog entry](https://data.norge.no/en/datasets/90c256d6-72f5-3261-ac37-250f65930df2/nobil-ladestasjoner-for-elbiler),
  [NOBIL description](https://info.nobil.no/om)
- Switzerland: [real-time charging dataset](https://data.opentransportdata.swiss/en/dataset/ladestationen),
  [SFOE API page](https://www.bfe.admin.ch/bfe/en/home/supply/digitalization-and-geoinformation/interfaces/ich-tanke-strom-api.html)
- UK: [National Charge Point Registry](https://www.data.gov.uk/dataset/1ce239a6-d720-4305-ab52-17793fedfac3/national-charge-point-registry),
  [Public Charge Point Regulations guidance](https://www.gov.uk/government/publications/the-public-charge-point-regulations-2023-guidance/public-charge-point-regulations-2023-guidance)
- Supplemental: [Open Charge Map API](https://www.openchargemap.org/develop/api)

## Prioritization strategy

1. Implement Bundesnetzagentur static ingestion to prove official bulk import,
   normalization, EVSE counting, unknown availability, PostGIS search, and source
   metadata on routes relevant to the initial German UI.
2. Add Switzerland `ich-tanke-strom` immediately to prove live status joins and a
   non-EU adapter, or reverse these two if live behavior is prioritized over German
   relevance.
3. Add Netherlands DOT-NL (live AFIR/OCPI) and France IRVE (large official corpus).
4. Add Norway NOBIL and UK registry/operator OCPI.
5. Expand EU country coverage through the NAP directory based on route demand and
   measured data quality; use Open Charge Map only as attributed open-only fallback.
6. Shadow-test CEAP against national sources after its production launch, then make
   it preferred per country only when coverage/freshness are at least equivalent.

## Gaps and risks

- AFIR compliance does not itself prove API discoverability, uptime, field
  completeness, or common semantics at every NAP.
- Location/station/cabinet/EVSE/connector meanings differ and must be mapped per
  source before counts are trusted.
- UK open data is decentralized by operator under OCPI even though the government
  registry can simplify access; completeness needs measurement.
- “Live” must have source-specific freshness and status mapping. Stale occupied or
  available values must become unknown rather than remain indefinitely actionable.
- Some open sources require registration/API keys. Secrets remain server-side and
  terms must permit caching/redistribution.
- A complete EU-27 endpoint/field audit belongs to provider rollout, not the first
  vertical slice. The NAP catalog supplies discovery while adapters remain isolated.

## Implemented German and Swiss authority feeds

The Bundesnetzagentur adapter discovers the most recent dated CSV link on the
official Ladesäulenkarte page rather than hard-coding a release URL. It accepts
only the allowlisted HTTPS data host and filename pattern, with byte, content-type,
schema, timeout, date, and SHA-256 validation. The source page labels the download
as CC BY 4.0 and requires attribution as `bundesnetzagentur.de`. Each numbered
`SteckertypenN` / `EVSE-IDN` block is one EVSE; semicolon-separated connector
types inside that block do not increase the count. Static register rows always
normalize to unknown, non-live availability.

The complete combined shadow import on 2026-08-15 used the current 2026-07-28
German CSV plus the current Swiss static feed. It produced 133,206 valid
locations, 224,995 normalized EVSE observations, 53,571 active charging parks,
1,068 quarantined source rows, and 181 explicit coordinate conflicts. Conflicting
observations remain distinct and are recorded for review rather than silently
merged.

The Swiss adapter uses the official SFOE `ich-tanke-strom` OICP static and status
JSON resources. A static record maps to exactly one EVSE even when it lists
multiple plugs. The live record with the same normalized provider EVSE key maps
`Available`, `Occupied`, `OutOfService`, and `Reserved` explicitly; `Unknown`,
`EvseNotFound`, missing records, stale feeds, and conflicting duplicate states all
remain unknown. Live snapshots refresh every minute, expire from search after five
minutes, and are retained for two hours to bound storage while preserving active
pagination. Attribution is `Bundesamt für Energie BFE, ich-tanke-strom.ch`.

The authority also announces a daily REST JSON/XML interface, but its OpenAPI
material is currently supplied on request rather than through an anonymously
reproducible public contract. The public versioned CSV remains the first adapter;
the provider boundary allows replacing its transport after that interface is
reviewed.
