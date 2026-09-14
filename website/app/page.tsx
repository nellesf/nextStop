import Image from "next/image";
import { imprint } from "../content/imprint";

const searchFacts = [
  {
    number: "01",
    title: "Vor der Fahrt festlegen",
    text: "Lege ausschließlich auf dem iPhone ein Profil mit Ziel, Entfernung, Mindestleistung, Anzahl der Ladepunkte und optional einer Restaurantkette an.",
  },
  {
    number: "02",
    title: "Unterwegs auswählen",
    text: "Starte dein gespeichertes Profil über CarPlay. Änderungen gelten nur für diese Fahrt – dein Originalprofil bleibt unverändert.",
  },
  {
    number: "03",
    title: "Bis zu fünf Stopps vergleichen",
    text: "nextStop filtert entlang der echten Route und sortiert ausschließlich nach tatsächlicher Fahrstrecke inklusive Abfahrt und Umweg.",
  },
] as const;

const principles = [
  {
    kicker: "Echte Route",
    title: "Nicht nur grob in Fahrtrichtung",
    text: "Ein Ladepark muss höchstens fünf Kilometer von der tatsächlichen MapKit-Route entfernt liegen.",
  },
  {
    kicker: "Echte Fahrstrecke",
    title: "Der Umweg zählt mit",
    text: "Die angezeigte Entfernung kommt von MapKit und enthält die Fahrt von deinem Standort bis zum Stopp – inklusive Abfahrt.",
  },
  {
    kicker: "Keine Tricks",
    title: "Deine Filter bleiben deine Filter",
    text: "Keine versteckte Bewertung, keine automatische Lockerung: erst filtern, dann nach Fahrstrecke sortieren, maximal fünf Treffer.",
  },
] as const;

function Brand() {
  return (
    <a className="brand" href="#top" aria-label="nextStop Startseite">
      <Image
        className="brand-icon"
        src="/app-icon.png"
        alt=""
        width={44}
        height={44}
        priority
        unoptimized
      />
      <span>nextStop</span>
    </a>
  );
}

function AppScreenshot({
  src,
  alt,
  caption,
  className = "",
}: {
  src: string;
  alt: string;
  caption: string;
  className?: string;
}) {
  return (
    <figure className={`device-column ${className}`}>
      <div className="phone screenshot-frame">
        <Image
          className="app-screenshot"
          src={src}
          alt={alt}
          width={1206}
          height={2622}
          sizes="(max-width: 620px) 260px, (max-width: 1180px) 221px, 261px"
          unoptimized
        />
      </div>
      <figcaption className="mockup-label">{caption}</figcaption>
    </figure>
  );
}

function CarPlayMockup() {
  return (
    <div className="carplay-wrap">
      <div className="carplay" role="img" aria-label="Designvorschau der nextStop CarPlay-Ergebnisse">
        <div className="carplay-rail">
          <span>17:46</span>
          <span className="rail-orb">◉</span>
          <span className="rail-orb">▦</span>
        </div>
        <div className="carplay-main">
          <header><span className="back-pill">‹ Profile</span><strong>Passende Stopps</strong><span className="refresh-pill">↻</span></header>
          <div className="carplay-content">
            <div className="map-panel">
              <div className="route-line route-one" />
              <div className="route-line route-two" />
              <span className="map-dot origin-dot" />
              <span className="map-dot stop-dot">⚡</span>
              <span className="road-label road-a">A 7</span>
              <span className="road-label road-b">B 209</span>
            </div>
            <div className="poi-panel">
              <span className="match-pill">1 von 3</span>
              <h3>McDonald’s<br />Ladepark Elbtal</h3>
              <p><strong>68 km</strong> Fahrstrecke</p>
              <div className="poi-capacity"><strong>26</strong><span>Ladepunkte<br />ab 150 kW</span></div>
              <div className="poi-providers">IONITY · EnBW · Tesla</div>
              <button type="button" tabIndex={-1}>In Apple Maps</button>
            </div>
          </div>
        </div>
      </div>
      <span className="mockup-label">Designvorschau · CarPlay</span>
    </div>
  );
}

export default function Home() {
  return (
    <main id="top">
      <header className="site-header">
        <Brand />
        <nav aria-label="Hauptnavigation">
          <a href="#story">Die Idee</a>
          <a href="#so-gehts">So geht’s</a>
          <a href="#ladepark">Ladepark verstehen</a>
          <a href="#privacy">Privatsphäre</a>
        </nav>
        <span className="status-badge"><i /> In Entwicklung</span>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <span className="eyebrow"><i /> Für iPhone &amp; Apple CarPlay entwickelt</span>
          <h1 id="hero-title">Hunger auf der Strecke?</h1>
          <p className="hero-lead">Finde den Stopp, der <em>Pause und Laden</em> zusammenbringt.</p>
          <p className="hero-support">nextStop zeigt dir bis zu fünf Ladeparks entlang deiner echten Route, die zu deinen Kriterien passen – auf Wunsch mit deiner bevorzugten Restaurantkette in Laufnähe.</p>
          <div className="hero-actions">
            <a className="primary-button" href="#so-gehts">So funktioniert nextStop <span>↓</span></a>
            <a className="text-link" href="#ladepark">Warum ein Ladepark mehr sagt <span>↗</span></a>
          </div>
          <div className="hero-proof" aria-label="Produktvorteile">
            <span><strong>≤ 5 km</strong> zur Route</span>
            <span><strong>≤ 5</strong> klare Treffer</span>
            <span><strong>1 Tipp</strong> für Apple Maps</span>
          </div>
        </div>

        <div className="hero-visual" aria-label="Eine Route verbindet Restaurant, Ladepark und Ziel">
          <div className="visual-glow" />
          <div className="hero-road">
            <span className="road-dash dash-one" />
            <span className="road-dash dash-two" />
            <span className="road-dash dash-three" />
          </div>
          <div className="route-node food-node"><span>🍔</span><small>Pause</small></div>
          <div className="route-node charge-node"><span>ϟ</span><small>Laden</small></div>
          <div className="route-node destination-node"><span>●</span><small>Hamburg</small></div>
          <div className="car-chip"><span>→</span><strong>unterwegs</strong></div>
          <div className="hero-result-card">
            <div className="hero-result-top"><span>PASSENDER STOPP</span><strong>68 km</strong></div>
            <h2>McDonald’s + Ladepark</h2>
            <p>26 Ladepunkte ab 150 kW</p>
            <div><span>IONITY</span><span>EnBW</span><span>Tesla</span></div>
          </div>
        </div>
      </section>

      <section className="story-section" id="story" aria-labelledby="story-title">
        <div className="section-heading wide-heading">
          <span className="section-index">01 · DIE SITUATION</span>
          <h2 id="story-title">Zwei Bedürfnisse.<br />Ein sinnvoller Stopp.</h2>
          <p>Du bekommst Hunger. Dein Akku braucht ohnehin bald eine Pause. nextStop sucht nicht nach irgendeinem Restaurant oder irgendeiner Säule, sondern nach der Kombination, die zu deiner Fahrt passt.</p>
        </div>
        <div className="moment-grid">
          <article className="moment-card hunger-card">
            <div className="moment-time">17:42</div>
            <div className="moment-icon">🍟</div>
            <div>
              <span>DER MOMENT</span>
              <h3>„Ich könnte langsam etwas essen.“</h3>
              <p>Dein Profil kennt bereits die Restaurantkette, die für diese Fahrt infrage kommt.</p>
            </div>
          </article>
          <article className="moment-card charge-card">
            <div className="moment-time">17:45</div>
            <div className="moment-icon">ϟ</div>
            <div>
              <span>DIE GELEGENHEIT</span>
              <h3>„Laden muss ich sowieso.“</h3>
              <p>Leistung, Parkgröße und Entfernung sind vorab festgelegt. Unterwegs reicht ein Profil-Tipp.</p>
            </div>
          </article>
          <article className="moment-card answer-card">
            <div className="moment-time">17:46</div>
            <div className="moment-icon">✓</div>
            <div>
              <span>DIE ANTWORT</span>
              <h3>Ein Stopp, der beides kann.</h3>
              <p>Bis zu fünf passende Ergebnisse – danach übernimmt Apple Maps die Navigation.</p>
            </div>
          </article>
        </div>
      </section>

      <section className="workflow-section" id="so-gehts" aria-labelledby="workflow-title">
        <div className="section-heading centered-heading">
          <span className="section-index">02 · SO GEHT’S</span>
          <h2 id="workflow-title">Einmal einstellen.<br />Unterwegs entspannt finden.</h2>
          <p>Profile und dauerhafte Vorlieben bereitest du ausschließlich auf dem iPhone vor. Während der Fahrt bleibt CarPlay bewusst knapp.</p>
        </div>

        <div className="workflow-list">
          {searchFacts.map((fact) => (
            <article key={fact.number}>
              <span>{fact.number}</span>
              <div><h3>{fact.title}</h3><p>{fact.text}</p></div>
            </article>
          ))}
        </div>

        <div className="device-stage phone-stage">
          <div className="stage-copy">
            <span className="stage-tag">IPHONE · VOR DER FAHRT</span>
            <h3>Deine Profile,<br />deine Kriterien.</h3>
            <p>Erstelle Profile für wiederkehrende Fahrten oder verschiedene Pausen. Name und Ziel bleiben lokal auf deinem iPhone.</p>
            <ul>
              <li>Entfernungsbereich von 15 bis 150 km</li>
              <li>Mindestleistung und Mindestanzahl an Ladepunkten</li>
              <li>Optional McDonald’s, Burger King, KFC oder Subway</li>
            </ul>
          </div>
          <div className="phones-composition">
            <AppScreenshot
              src="/screenshots/iphone-profiles.png"
              alt="Die nextStop Profilübersicht mit gespeicherten Beispielprofilen auf dem iPhone"
              caption="App-Aufnahme · Meine Profile"
            />
            <AppScreenshot
              src="/screenshots/iphone-profile-editor.png"
              alt="Ein nextStop Beispielprofil im Editor mit Name, Ziel und Suchkriterien"
              caption="App-Aufnahme · Profil bearbeiten"
              className="editor-device"
            />
          </div>
        </div>

        <div className="device-stage carplay-stage">
          <div className="stage-copy">
            <span className="stage-tag dark-tag">CARPLAY · WÄHREND DER FAHRT</span>
            <h3>Wenig tippen.<br />Klar entscheiden.</h3>
            <p>Wähle ein Profil, vergleiche maximal fünf Stopps und übergib deinen Favoriten an Apple Maps. nextStop bleibt Suche – Apple Maps bleibt Navigation.</p>
          </div>
          <CarPlayMockup />
        </div>

        <div className="device-stage results-stage">
          <div className="fact-callout filter-distance">
            <span>500 m</span>
            <p>Maximaler geodesischer Abstand zwischen der gewählten Restaurantkette und einem passenden Ladepark.</p>
          </div>
          <div className="stage-copy">
            <span className="stage-tag">IPHONE · DEINE FILTER</span>
            <h3>Vorbereiten.<br />Nur auf dem iPhone.</h3>
            <p>Profile und dauerhafte Vorlieben richtest du vor der Fahrt ausschließlich auf dem iPhone ein. Wähle die passende Mindestleistung, die Anzahl der Ladepunkte und bei Bedarf deine Restaurantkette. Unterwegs reicht in CarPlay die Auswahl des vorbereiteten Profils.</p>
          </div>
        </div>
        <p className="mockup-disclaimer">Die iPhone-Bilder zeigen echte Aufnahmen der unveröffentlichten App mit Beispielprofilen. Die CarPlay-Abbildung ist eine Designvorschau; ihre Darstellung kann von der App abweichen.</p>
      </section>

      <section className="capacity-section" id="ladepark" aria-labelledby="capacity-title">
        <div className="capacity-intro">
          <span className="section-index light-index">03 · MEHR KONTEXT</span>
          <h2 id="capacity-title">Zwei sind frei.<br />Aber wie lange noch?</h2>
          <p>Dein Auto zeigt dir vielleicht den nächsten Anbieter mit zwei aktuell freien Ladepunkten. Bis du dort ankommst, kann diese Momentaufnahme längst anders aussehen.</p>
          <p>nextStop schaut deshalb breiter: auf den anbieterübergreifenden Ladepark und seine insgesamt erfasste Kapazität ab deiner Mindestleistung.</p>
        </div>

        <div className="capacity-demo">
          <div className="snapshot-card">
            <span className="demo-label">DEIN AUTO ZEIGT</span>
            <div className="provider-head"><span className="provider-mark">A</span><div><strong>Anbieter A</strong><small>nächster Ladestopp</small></div></div>
            <div className="availability-big"><strong>2</strong><span>aktuell frei</span></div>
            <p>Momentaufnahme – keine Prognose für deine Ankunft.</p>
          </div>

          <div className="perspective-arrow"><span>+</span><small>mehr<br />Kontext</small></div>

          <div className="park-card">
            <div className="park-card-head"><div><span className="demo-label">NEXTSTOP ZEIGT</span><h3>Ladepark Elbtal</h3></div><span className="route-distance">68 km</span></div>
            <div className="total-capacity"><strong>26</strong><div><span>Ladepunkte</span><small>ab 150 kW erfasst</small></div></div>
            <div className="provider-rows">
              <div><span className="provider-mark lime-mark">A</span><strong>Anbieter A</strong><span>12 Ladepunkte</span><small className="live">2 / 12 frei</small></div>
              <div><span className="provider-mark aqua-mark">B</span><strong>Anbieter B</strong><span>8 Ladepunkte</span><small className="live">5 / 8 frei</small></div>
              <div><span className="provider-mark white-mark">C</span><strong>Anbieter C</strong><span>6 Ladepunkte</span><small className="live">3 / 6 frei</small></div>
            </div>
            <p className="capacity-caveat">Auslastung ist eine Momentaufnahme, wird je nach verfügbarer Datenlage angezeigt und beeinflusst weder Auswahl noch Reihenfolge.</p>
          </div>
        </div>

      </section>

      <section className="principles-section" aria-labelledby="principles-title">
        <div className="section-heading wide-heading">
          <span className="section-index">04 · DARAUF KANNST DU DICH VERLASSEN</span>
          <h2 id="principles-title">Was „entlang der Route“<br />bei nextStop bedeutet.</h2>
        </div>
        <div className="principles-grid">
          {principles.map((principle, index) => (
            <article key={principle.kicker}>
              <span className="principle-number">0{index + 1}</span>
              <span className="principle-kicker">{principle.kicker}</span>
              <h3>{principle.title}</h3>
              <p>{principle.text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="privacy-section" id="privacy" aria-labelledby="privacy-title">
        <div className="privacy-card">
          <div className="privacy-copy">
            <span className="section-index light-index">05 · PRIVATSPHÄRE</span>
            <h2 id="privacy-title">Deine Vorlieben<br />bleiben deine.</h2>
            <p>Profile, Favoriten und zuletzt verwendete Ziele bleiben auf deinem iPhone. Du brauchst kein Konto und nextStop zeigt keine Werbung.</p>
            <p>Für die Suche wird deine Route kurzzeitig verwendet. Danach wird sie nicht gespeichert und nextStop erstellt daraus kein persönliches Nutzungsprofil.</p>
          </div>
          <div className="privacy-facts">
            <div><span>01</span><p><strong>Profile und Vorlieben</strong> bleiben auf deinem iPhone</p></div>
            <div><span>02</span><p><strong>Favoriten und letzte Ziele</strong> bleiben auf deinem iPhone</p></div>
            <div><span>03</span><p><strong>Kein Konto</strong> und keine Werbung</p></div>
            <div><span>04</span><p><strong>Route nur für die Suche</strong> und danach nicht gespeichert</p></div>
          </div>
        </div>
      </section>

      <section className="faq-section" aria-labelledby="faq-title">
        <div className="section-heading faq-heading">
          <span className="section-index">06 · KURZ GEKLÄRT</span>
          <h2 id="faq-title">Noch eine Frage?</h2>
        </div>
        <div className="faq-list">
          <details>
            <summary>Plant nextStop meine komplette Ladereise?<span>＋</span></summary>
            <p>Nein. nextStop findet passende Pausenstopps entlang einer bestehenden Route. Navigation und Routenführung übernimmt Apple Maps.</p>
          </details>
          <details>
            <summary>Garantiert die App freie Ladepunkte bei Ankunft?<span>＋</span></summary>
            <p>Nein. Verfügbarkeit ist eine Momentaufnahme, rein informativ und kein Filter. nextStop hilft dir vor allem, Kapazität und Betreiber-Auswahl eines Ladeparks einzuschätzen.</p>
          </details>
          <details>
            <summary>Kann ich Profile in CarPlay ändern?<span>＋</span></summary>
            <p>Du kannst Kriterien für die aktuelle Fahrt anpassen. Gespeicherte Profile werden ausschließlich in der iPhone-App gepflegt und bleiben dabei unverändert.</p>
          </details>
          <details>
            <summary>Wo funktioniert nextStop?<span>＋</span></summary>
            <p>Die aktuelle Datenbasis ist für Deutschland und die Schweiz ausgelegt. nextStop befindet sich noch in Entwicklung.</p>
          </details>
        </div>
      </section>

      <section className="imprint-section" id="impressum" aria-labelledby="imprint-title">
        <div className="imprint-heading">
          <span className="section-index">07 · RECHTLICHES</span>
          <h2 id="imprint-title">Impressum</h2>
          <p>Angaben gemäß § 5 DDG und § 18 Abs. 1 MStV</p>
        </div>
        <div className="imprint-card">
          {imprint.placeholdersActive && (
            <div className="imprint-warning" role="status">
              <strong>Anonyme Platzhalter</strong>
              <span>Diese Angaben sind nur für die private Designvorschau und müssen vor einer öffentlichen Veröffentlichung ersetzt werden.</span>
            </div>
          )}
          <div className="imprint-details">
            <div>
              <span>Anbieter</span>
              <address>
                <strong>{imprint.fullName}</strong><br />
                {imprint.streetAndNumber}<br />
                {imprint.postalCode} {imprint.city}<br />
                {imprint.country}
              </address>
            </div>
            <div>
              <span>Kontakt</span>
              <p>
                E-Mail: {imprint.email}<br />
                Telefon: {imprint.phone}
              </p>
            </div>
          </div>
          <p className="imprint-note">Verantwortlich für dieses Telemedienangebot ist die oben genannte natürliche Person.</p>
        </div>
      </section>

      <section className="closing-section">
        <Image src="/app-icon.png" alt="nextStop App-Icon" width={88} height={88} unoptimized />
        <span className="section-index light-index">DEIN NÄCHSTER STOPP</span>
        <h2>Pause machen.<br />Weiterkommen.</h2>
        <p>nextStop wird für iPhone und Apple CarPlay entwickelt.</p>
        <span className="development-pill"><i /> Aktuell in Entwicklung</span>
      </section>

      <footer>
        <Brand />
        <p>Finde passende Ladeparks entlang deiner Route.</p>
        <div><a href="#privacy">Privatsphäre</a><a href="#impressum">Impressum</a><a href="#top">Nach oben ↑</a></div>
        <small>© 2026 nextStop · Restaurantdaten © OpenStreetMap-Mitwirkende</small>
      </footer>
    </main>
  );
}
