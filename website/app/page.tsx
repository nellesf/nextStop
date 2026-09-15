import Image from "next/image";
import { imprint } from "../content/imprint";
import {
  carplayResultScreenshots,
  iphoneResultScreenshots,
  type ResultScreenshot,
} from "../content/result-screenshots";

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
        <a className="screenshot-link" href={src} aria-label={`${alt} in Originalgröße öffnen`}>
          <Image
            className="app-screenshot"
            src={src}
            alt={alt}
            width={1206}
            height={2622}
            sizes="(max-width: 620px) 260px, 280px"
            unoptimized
          />
        </a>
      </div>
      <figcaption className="screen-caption">{caption}</figcaption>
    </figure>
  );
}

function CarPlayScreenshot({ src, alt, caption, width = 800, height = 480 }: ResultScreenshot) {
  return (
    <figure className="carplay-wrap">
      <div className="carplay">
        <a className="screenshot-link" href={src} aria-label={`${alt} in Originalgröße öffnen`}>
          <Image
            className="carplay-screenshot"
            src={src}
            alt={alt}
            width={width}
            height={height}
            sizes="(max-width: 620px) calc(100vw - 52px), 640px"
            unoptimized
          />
        </a>
      </div>
      <figcaption className="screen-caption">{caption}</figcaption>
    </figure>
  );
}

function CombinedStop() {
  return (
    <div className="combined-stop-scene" role="img" aria-label="Ein gemeinsamer Stopp zum Laden und Essen auf deiner Fahrt">
      <svg className="journey-road" viewBox="0 0 600 600" fill="none" aria-hidden="true">
        <path d="M 28 560 C 25 405 155 472 185 355 S 450 238 424 128 S 478 32 584 40" stroke="currentColor" strokeWidth="72" />
        <path d="M 28 560 C 25 405 155 472 185 355 S 450 238 424 128 S 478 32 584 40" stroke="#f5f5ed" strokeWidth="3" strokeDasharray="15 17" />
      </svg>
      <div className="combined-stop-card">
        <span className="eyebrow">DEINE NÄCHSTE PAUSE</span>
        <div className="combined-stop-icons" aria-hidden="true"><span>ϟ</span><b>+</b><span>🍔</span></div>
        <strong>Laden &amp; Essen</strong>
        <p>Ein Stopp.<br />Zeit für beides.</p>
        <span className="combined-stop-foot">Restaurant beim Ladepark</span>
      </div>
    </div>
  );
}

export default function Home() {
  const phoneResults = iphoneResultScreenshots[0];
  const carplayResults = carplayResultScreenshots[0];
  return (
    <main id="top">
      <header className="site-header">
        <Brand />
        <nav aria-label="Hauptnavigation">
          <a href="#idee">Die Idee</a>
          <a href="#so-gehts">So geht’s</a>
          <a href="#fragen">Fragen</a>
        </nav>
        <span className="status-badge"><i /> In Entwicklung</span>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <span className="eyebrow">FÜR IPHONE &amp; APPLE CARPLAY</span>
          <h1 id="hero-title">Dein Auto lädt.<br /><em>Du machst Pause.</em></h1>
          <p className="hero-lead">Lass dir nicht vom Auto vorschreiben, wann und wo du Pause machst.</p>
          <p className="hero-support">Du hast Hunger und dein Auto braucht Strom? Finde einen Ladepark mit einem Restaurant in der Nähe. So wird aus Laden und Essen eine gemeinsame Pause – an einem Stopp, der zu dir passt.</p>
          <a className="primary-button" href="#so-gehts">So findest du deinen Stopp <span>↓</span></a>
          <p className="hero-footnote">Deine Wünsche. Dein Ladestopp. Deine Pause.</p>
        </div>
        <CombinedStop />
      </section>

      <section className="idea-section" id="idee" aria-labelledby="idea-title">
        <div className="idea-heading">
          <span className="eyebrow">PAUSE NACH DEINEN BEDÜRFNISSEN</span>
          <h2 id="idea-title">Essen gehen,<br />während dein Auto lädt.</h2>
        </div>
        <div className="idea-copy">
          <p>Erst laden und danach noch einmal fürs Essen anhalten? Das geht auch zusammen. Wähle deine bevorzugte Restaurantkette und finde Ladeparks in ihrer Nähe.</p>
          <div className="more-choice">
            <span aria-hidden="true">ϟ</span>
            <div>
              <h3>Und vor Ort mehr Auswahl haben.</h3>
              <p>Ein Ladepunkt ist belegt, der andere defekt – mitten im Nirgendwo möchtest du so nicht ankommen. Lege fest, wie viele Ladepunkte ein Standort mindestens haben soll. nextStop berücksichtigt dabei auch mehrere Anbieter am selben Stopp.</p>
            </div>
          </div>
        </div>
      </section>

      <section className="journey-section" id="so-gehts" aria-labelledby="journey-title">
        <div className="journey-intro">
          <span className="eyebrow">SO GEHT’S</span>
          <h2 id="journey-title">In drei Schritten<br />zu deiner nächsten Pause.</h2>
          <nav className="journey-nav" aria-label="Die drei Schritte">
            <a href="#profil"><span>1</span> Profil anlegen</a>
            <a href="#losfahren"><span>2</span> Losfahren</a>
            <a href="#stopp"><span>3</span> Passenden Stopp finden</a>
          </nav>
        </div>

        <ol className="journey-steps">
          <li className="journey-step profile-step" id="profil">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">1</span>
              <div><span className="eyebrow">VOR DER FAHRT · AUF DEM IPHONE</span><h3>Profil für deine<br />nächste Fahrt anlegen.</h3></div>
            </div>
            <div className="profile-layout">
              <div className="step-copy">
                <p>Wohin geht’s, und was brauchst du für eine gute Pause? Speichere dein Ziel und deine Wünsche vor dem Losfahren auf dem iPhone.</p>
                <ul className="preference-list">
                  <li><strong>Dein Ziel</strong><span>Wohin du fahren möchtest.</span></li>
                  <li><strong>Dein Ladestopp</strong><span>In welcher Entfernung du suchen möchtest, wie viele Ladepunkte es mindestens geben soll und welche Ladeleistung du brauchst.</span></li>
                  <li><strong>Deine Essenspause</strong><span>Auf Wunsch mit McDonald’s, Burger King, KFC oder Subway in der Nähe.</span></li>
                </ul>
                <p className="quiet-note">Für die nächste ähnliche Fahrt ist dein Profil schon gespeichert.</p>
              </div>
              <div className="profile-screens">
                <AppScreenshot src="/screenshots/iphone-profile-editor.png" alt="nextStop auf dem iPhone: Profil für die nächste Fahrt mit Ziel und Wünschen anlegen" caption="Ziel und Wünsche eintragen" />
                <AppScreenshot src="/screenshots/iphone-profiles.png" alt="nextStop auf dem iPhone: gespeicherte Fahrtprofile" caption="Dein Profil ist bereit" />
              </div>
            </div>
          </li>

          <li className="journey-step drive-step" id="losfahren">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">2</span>
              <div><span className="eyebrow">UNTERWEGS · IN CARPLAY</span><h3>Losfahren.<br />Dein Profil ist schon dabei.</h3></div>
            </div>
            <p className="step-lead">Wenn du unterwegs einen Stopp suchst, wählst du dein vorbereitetes Profil in CarPlay aus. Dein Ziel und deine Wünsche sind schon da.</p>
            <div className="carplay-pair">
              <CarPlayScreenshot src="/screenshots/carplay-wide/carplay-profiles.png" width={1920} height={720} alt="nextStop in CarPlay: die vorbereitete Fahrt auswählen" caption="Deine Fahrt auswählen" />
              <CarPlayScreenshot src="/screenshots/carplay-wide/carplay-ride-summary.png" width={1920} height={720} alt="nextStop in CarPlay: gespeicherte Wünsche prüfen und die Suche starten" caption="Bereit für die Suche" />
            </div>
          </li>

          <li className="journey-step find-step" id="stopp">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">3</span>
              <div><span className="eyebrow">WENN ES ZEIT FÜR DEINE PAUSE IST</span><h3>Den passenden Stopp finden.<br />Laden und Essen verbinden.</h3></div>
            </div>
            <p className="step-lead">Starte die Suche. nextStop zeigt dir bis zu fünf Stopps entlang deiner Fahrt, die zu deinen Wünschen passen. Der nächste steht zuerst – die angezeigte Fahrstrecke zählt die Abfahrt und den Weg zum Stopp mit.</p>
            <p className="image-note">Echte Aufnahmen aus der App in Entwicklung. Ladepunktzahlen und Ladeleistungen in nextStop sind Beispielwerte. Eine aktuelle Belegung wird in diesen Bildern nicht gezeigt.</p>

            <div className="result-comparison" aria-label="Suchergebnisse auf iPhone und CarPlay">
              {carplayResults && <div className="carplay-result"><h4>Unterwegs in CarPlay</h4><CarPlayScreenshot {...carplayResults} /><p className="result-explanation">Restaurant, Ladepunkte und Entfernung gehören zu einem gemeinsamen Stopp. Du entscheidest, welcher zu deiner Pause passt.</p></div>}
              {phoneResults && <div className="phone-result"><h4>Auch auf dem iPhone</h4><AppScreenshot {...phoneResults} /></div>}
            </div>

            <div className="arrival-choice">
              <div className="arrival-heading">
                <span className="eyebrow">DEINEN STOPP ANSTEUERN</span>
                <h4>Eine Pause.<br />Du wählst, wo du ankommst.</h4>
                <p>Öffne den Ladeanbieter oder das Restaurant als Ziel. Beide gehören zu deinem gewählten Pausenstopp. Apple Maps führt dich zu dem Ort, den du antippst.</p>
              </div>
              <div className="carplay-pair">
                {carplayResultScreenshots.slice(1).map((screen) => <CarPlayScreenshot key={screen.src} {...screen} />)}
              </div>
              {iphoneResultScreenshots.length > 1 && (
                <details className="maps-details">
                  <summary>So sieht dein ausgewähltes Ziel in Apple Maps aus <span>＋</span></summary>
                  <div className="maps-content">
                    <p>Hier siehst du das Restaurant und den Ladeanbieter desselben Stopps. Apple Maps zeigt seine eigenen Ortsangaben.</p>
                    <div className="maps-screens">{iphoneResultScreenshots.slice(1).map((screen) => <AppScreenshot key={screen.src} {...screen} />)}</div>
                  </div>
                </details>
              )}
            </div>
          </li>
        </ol>
        <div className="journey-outcome"><span aria-hidden="true">ϟ + 🍔</span><p>Einmal anhalten.<br /><strong>Deine Ladezeit wird zur Essenspause.</strong></p></div>
      </section>

      <section className="privacy-section" id="privacy" aria-labelledby="privacy-title">
        <div className="privacy-card">
          <div className="privacy-copy">
            <span className="section-index light-index">DEINE PRIVATSPHÄRE</span>
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

      <section className="faq-section" id="fragen" aria-labelledby="faq-title">
        <div className="section-heading faq-heading">
          <span className="section-index">GUT ZU WISSEN</span>
          <h2 id="faq-title">Noch eine Frage?</h2>
        </div>
        <div className="faq-list">
          <details>
            <summary>Plant nextStop meine komplette Ladereise?<span>＋</span></summary>
            <p>nextStop hilft dir, den nächsten passenden Stopp zu finden. Du entscheidest, wo du Pause machst. Apple Maps führt dich zum ausgewählten Ort.</p>
          </details>
          <details>
            <summary>Garantiert die App freie Ladepunkte bei Ankunft?<span>＋</span></summary>
            <p>Nein. Auch ein jetzt freier Ladepunkt kann bei deiner Ankunft belegt sein. Du kannst aber gezielt nach Standorten mit mehreren Ladepunkten suchen, damit du vor Ort mehr Auswahl hast.</p>
          </details>
          <details>
            <summary>Und wenn ich nichts essen möchte?<span>＋</span></summary>
            <p>Dann lässt du die Restaurantwahl im Profil einfach weg. nextStop sucht einen Ladestopp, der zu deinen übrigen Wünschen passt.</p>
          </details>
          <details>
            <summary>Kann ich Profile in CarPlay ändern?<span>＋</span></summary>
            <p>Dein Profil legst du vor der Fahrt auf dem iPhone an. In CarPlay kannst du deine Wünsche für die aktuelle Fahrt anpassen. Dein gespeichertes Profil bleibt dabei erhalten.</p>
          </details>
          <details>
            <summary>Wo funktioniert nextStop?<span>＋</span></summary>
            <p>nextStop wird zunächst für Fahrten in Deutschland und der Schweiz entwickelt. nextStop befindet sich noch in Entwicklung.</p>
          </details>
        </div>
      </section>

      <section className="imprint-section" id="impressum" aria-labelledby="imprint-title">
        <div className="imprint-heading">
          <span className="section-index">RECHTLICHES</span>
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
          <p className="imprint-note">Verantwortlich für dieses Angebot ist die oben genannte natürliche Person.</p>
        </div>
      </section>

      <section className="closing-section">
        <Image src="/app-icon.png" alt="nextStop App-Icon" width={88} height={88} unoptimized />
        <span className="section-index light-index">DEIN NÄCHSTER STOPP</span>
        <h2>Eine Pause für dich.<br />Und dein Auto.</h2>
        <p>nextStop wird für iPhone und Apple CarPlay entwickelt.</p>
        <span className="development-pill"><i /> Aktuell in Entwicklung</span>
      </section>

      <footer>
        <Brand />
        <p>Laden und Pause machen. An einem Stopp.</p>
        <div><a href="#privacy">Privatsphäre</a><a href="#impressum">Impressum</a><a href="#top">Nach oben ↑</a></div>
        <small>© 2026 nextStop · Restaurantdaten © OpenStreetMap-Mitwirkende</small>
      </footer>
    </main>
  );
}
