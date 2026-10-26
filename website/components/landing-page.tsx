import Image from "next/image";
import { landingCopy, type LandingCopy, type WebsiteLocale } from "../content/landing-copy";
import { imprint } from "../content/imprint";
import {
  carplayResultScreenshots,
  iphoneResultScreenshots,
  type ResultScreenshot,
} from "../content/result-screenshots";

function Brand({ copy }: { copy: LandingCopy }) {
  return (
    <a className="brand" href="#top" aria-label={copy.homeLabel}>
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
  copy,
}: {
  src: string;
  alt: string;
  caption: string;
  className?: string;
  copy: LandingCopy;
}) {
  return (
    <figure className={`device-column ${className}`}>
      <div className="phone screenshot-frame">
        <a className="screenshot-link" href={src} aria-label={`${alt} ${copy.openOriginal}`}>
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

function CarPlayScreenshot({ src, alt, caption, width = 800, height = 480, copy }: ResultScreenshot & { copy: LandingCopy }) {
  return (
    <figure className="carplay-wrap">
      <div className="carplay">
        <a className="screenshot-link" href={src} aria-label={`${alt} ${copy.openOriginal}`}>
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

function CombinedStop({ copy }: { copy: LandingCopy }) {
  return (
    <div className="combined-stop-scene" role="img" aria-label={copy.sceneLabel}>
      <svg className="journey-road" viewBox="0 0 600 600" fill="none" aria-hidden="true">
        <path d="M 28 560 C 25 405 155 472 185 355 S 450 238 424 128 S 478 32 584 40" stroke="currentColor" strokeWidth="72" />
        <path d="M 28 560 C 25 405 155 472 185 355 S 450 238 424 128 S 478 32 584 40" stroke="#f5f5ed" strokeWidth="3" strokeDasharray="15 17" />
      </svg>
      <div className="combined-stop-card">
        <span className="eyebrow">{copy.sceneEyebrow}</span>
        <div className="combined-stop-icons" aria-hidden="true"><span>ϟ</span><b>+</b><span>🍔</span></div>
        <strong>{copy.sceneTitle}</strong>
        <p>{copy.sceneLineOne}<br />{copy.sceneLineTwo}</p>
        <span className="combined-stop-foot">{copy.sceneFoot}</span>
      </div>
    </div>
  );
}

export function LandingPage({ locale }: { locale: WebsiteLocale }) {
  const copy = landingCopy[locale];
  const phoneScreens = iphoneResultScreenshots.map((screen, index) => ({
    ...screen,
    ...copy.iphoneResults[index],
  }));
  const carplayScreens = carplayResultScreenshots.map((screen, index) => ({
    ...screen,
    ...copy.carplayResults[index],
  }));
  const phoneResults = phoneScreens[0];
  const carplayResults = carplayScreens[0];
  const displayImprint = locale === "en" && imprint.placeholdersActive
    ? { ...imprint, ...copy.imprintPlaceholders }
    : imprint;
  return (
    <main id="top">
      <header className="site-header">
        <Brand copy={copy} />
        <nav aria-label={copy.mainNavigation}>
          <a href="#idee">{copy.navIdea}</a>
          <a href="#so-gehts">{copy.navHow}</a>
          <a href="#fragen">{copy.navQuestions}</a>
        </nav>
        <div className="header-actions">
          <div className="language-switcher" role="group" aria-label={copy.languageLabel}>
            {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- Full document navigation preserves locale-specific layouts and metadata in the static export. */}
            <a href="/" hrefLang="de" lang="de" aria-current={locale === "de" ? "page" : undefined}>Deutsch</a>
            <span aria-hidden="true">/</span>
            <a href="/en/" hrefLang="en" lang="en" aria-current={locale === "en" ? "page" : undefined}>English</a>
          </div>
          <span className="status-badge"><i /> {copy.development}</span>
        </div>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <span className="eyebrow">{copy.heroEyebrow}</span>
          <h1 id="hero-title">{copy.heroTitle}<br /><em>{copy.heroEmphasis}</em></h1>
          <p className="hero-lead">{copy.heroLead}</p>
          <p className="hero-support">{copy.heroSupport}</p>
          <a className="primary-button" href="#so-gehts">{copy.heroButton} <span>↓</span></a>
          <p className="hero-footnote">{copy.heroFootnote}</p>
        </div>
        <CombinedStop copy={copy} />
      </section>

      <section className="idea-section" id="idee" aria-labelledby="idea-title">
        <div className="idea-heading">
          <span className="eyebrow">{copy.ideaEyebrow}</span>
          <h2 id="idea-title">{copy.ideaTitle}<br />{copy.ideaTitleEnd}</h2>
        </div>
        <div className="idea-copy">
          <p>{copy.ideaBody}</p>
          <div className="more-choice">
            <span aria-hidden="true">ϟ</span>
            <div>
              <h3>{copy.choiceTitle}</h3>
              <p>{copy.choiceBody}</p>
            </div>
          </div>
        </div>
      </section>

      <section className="journey-section" id="so-gehts" aria-labelledby="journey-title">
        <div className="journey-intro">
          <span className="eyebrow">{copy.journeyEyebrow}</span>
          <h2 id="journey-title">{copy.journeyTitle}<br />{copy.journeyTitleEnd}</h2>
          <nav className="journey-nav" aria-label={copy.journeyNavigation}>
            <a href="#profil"><span>1</span> {copy.navProfile}</a>
            <a href="#losfahren"><span>2</span> {copy.navDrive}</a>
            <a href="#stopp"><span>3</span> {copy.navFind}</a>
          </nav>
        </div>

        <ol className="journey-steps">
          <li className="journey-step profile-step" id="profil">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">1</span>
              <div><span className="eyebrow">{copy.profileEyebrow}</span><h3>{copy.profileTitle}<br />{copy.profileTitleEnd}</h3></div>
            </div>
            <div className="profile-layout">
              <div className="step-copy">
                <p>{copy.profileLead}</p>
                <ul className="preference-list">
                  <li><strong>{copy.destinationTitle}</strong><span>{copy.destinationBody}</span></li>
                  <li><strong>{copy.chargingTitle}</strong><span>{copy.chargingBody}</span></li>
                  <li><strong>{copy.foodTitle}</strong><span>{copy.foodBody}</span></li>
                </ul>
                <p className="quiet-note">{copy.profileNote}</p>
              </div>
              <div className="profile-screens">
                <AppScreenshot copy={copy} src="/screenshots/iphone-profile-editor.png" alt={copy.profileEditorAlt} caption={copy.profileEditorCaption} />
                <AppScreenshot copy={copy} src="/screenshots/iphone-profiles.png" alt={copy.profilesAlt} caption={copy.profilesCaption} />
              </div>
            </div>
          </li>

          <li className="journey-step drive-step" id="losfahren">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">2</span>
              <div><span className="eyebrow">{copy.driveEyebrow}</span><h3>{copy.driveTitle}<br />{copy.driveTitleEnd}</h3></div>
            </div>
            <p className="step-lead">{copy.driveLead}</p>
            <div className="carplay-pair">
              <CarPlayScreenshot copy={copy} src="/screenshots/carplay-wide/carplay-profiles.png" width={1920} height={720} alt={copy.carplayProfilesAlt} caption={copy.carplayProfilesCaption} />
              <CarPlayScreenshot copy={copy} src="/screenshots/carplay-wide/carplay-ride-summary.png" width={1920} height={720} alt={copy.carplaySummaryAlt} caption={copy.carplaySummaryCaption} />
            </div>
          </li>

          <li className="journey-step find-step" id="stopp">
            <div className="step-heading">
              <span className="step-number" aria-hidden="true">3</span>
              <div><span className="eyebrow">{copy.findEyebrow}</span><h3>{copy.findTitle}<br />{copy.findTitleEnd}</h3></div>
            </div>
            <p className="step-lead">{copy.findLead}</p>
            <p className="image-note">{copy.imageNote}</p>

            <div className="result-comparison" aria-label={copy.resultComparisonLabel}>
              {carplayResults && <div className="carplay-result"><h4>{copy.carplayResultsTitle}</h4><CarPlayScreenshot copy={copy} {...carplayResults} /><p className="result-explanation">{copy.resultsExplanation}</p></div>}
              {phoneResults && <div className="phone-result"><h4>{copy.iphoneResultsTitle}</h4><AppScreenshot copy={copy} {...phoneResults} /></div>}
            </div>

            <div className="arrival-choice">
              <div className="arrival-heading">
                <span className="eyebrow">{copy.arrivalEyebrow}</span>
                <h4>{copy.arrivalTitle}<br />{copy.arrivalTitleEnd}</h4>
                <p>{copy.arrivalBody}</p>
              </div>
              <div className="carplay-pair">
                {carplayScreens.slice(1).map((screen) => <CarPlayScreenshot copy={copy} key={screen.src} {...screen} />)}
              </div>
              {phoneScreens.length > 1 && (
                <details className="maps-details">
                  <summary>{copy.mapsSummary} <span>＋</span></summary>
                  <div className="maps-content">
                    <p>{copy.mapsBody}</p>
                    <div className="maps-screens">{phoneScreens.slice(1).map((screen) => <AppScreenshot copy={copy} key={screen.src} {...screen} />)}</div>
                  </div>
                </details>
              )}
            </div>
          </li>
        </ol>
        <div className="journey-outcome"><span aria-hidden="true">ϟ + 🍔</span><p>{copy.outcomeTitle}<br /><strong>{copy.outcomeBody}</strong></p></div>
      </section>

      <section className="privacy-section" id="privacy" aria-labelledby="privacy-title">
        <div className="privacy-card">
          <div className="privacy-copy">
            <span className="section-index light-index">{copy.privacyEyebrow}</span>
            <h2 id="privacy-title">{copy.privacyTitle}<br />{copy.privacyTitleEnd}</h2>
            <p>{copy.privacyBody}</p>
            <p>{copy.privacyRouteBody}</p>
          </div>
          <div className="privacy-facts">
            <div><span>01</span><p><strong>{copy.privacyProfiles}</strong>{copy.privacyStay}</p></div>
            <div><span>02</span><p><strong>{copy.privacyFavourites}</strong>{copy.privacyStay}</p></div>
            <div><span>03</span><p><strong>{copy.privacyAccount}</strong>{copy.privacyAds}</p></div>
            <div><span>04</span><p><strong>{copy.privacyRoute}</strong>{copy.privacyNotStored}</p></div>
          </div>
        </div>
      </section>

      <section className="faq-section" id="fragen" aria-labelledby="faq-title">
        <div className="section-heading faq-heading">
          <span className="section-index">{copy.faqEyebrow}</span>
          <h2 id="faq-title">{copy.faqTitle}</h2>
        </div>
        <div className="faq-list">
          <details>
            <summary>{copy.faqTripQuestion}<span>＋</span></summary>
            <p>{copy.faqTripAnswer}</p>
          </details>
          <details>
            <summary>{copy.faqAvailabilityQuestion}<span>＋</span></summary>
            <p>{copy.faqAvailabilityAnswer}</p>
          </details>
          <details>
            <summary>{copy.faqFoodQuestion}<span>＋</span></summary>
            <p>{copy.faqFoodAnswer}</p>
          </details>
          <details>
            <summary>{copy.faqProfileQuestion}<span>＋</span></summary>
            <p>{copy.faqProfileAnswer}</p>
          </details>
          <details>
            <summary>{copy.faqWhereQuestion}<span>＋</span></summary>
            <p>{copy.faqWhereAnswer}</p>
          </details>
        </div>
      </section>

      <section className="imprint-section" id="impressum" aria-labelledby="imprint-title">
        <div className="imprint-heading">
          <span className="section-index">{copy.legalEyebrow}</span>
          <h2 id="imprint-title">{copy.legalTitle}</h2>
          <p>{copy.legalBasis}</p>
        </div>
        <div className="imprint-card">
          {imprint.placeholdersActive && (
            <div className="imprint-warning" role="status">
              <strong>{copy.placeholderTitle}</strong>
              <span>{copy.placeholderBody}</span>
            </div>
          )}
          <div className="imprint-details">
            <div>
              <span>{copy.providerLabel}</span>
              <address>
                <strong>{displayImprint.fullName}</strong><br />
                {displayImprint.streetAndNumber}<br />
                {displayImprint.postalCode} {displayImprint.city}<br />
                {displayImprint.country}
              </address>
            </div>
            <div>
              <span>{copy.contactLabel}</span>
              <p>
                {copy.emailLabel}: {displayImprint.email}<br />
                {copy.phoneLabel}: {displayImprint.phone}
              </p>
            </div>
          </div>
          <p className="imprint-note">{copy.legalResponsibility}</p>
        </div>
      </section>

      <section className="closing-section">
        <Image src="/app-icon.png" alt={copy.appIconAlt} width={88} height={88} unoptimized />
        <span className="section-index light-index">{copy.closingEyebrow}</span>
        <h2>{copy.closingTitle}<br />{copy.closingTitleEnd}</h2>
        <p>{copy.closingBody}</p>
        <span className="development-pill"><i /> {copy.closingDevelopment}</span>
      </section>

      <footer>
        <Brand copy={copy} />
        <p>{copy.footerBody}</p>
        <div><a href="#privacy">{copy.footerPrivacy}</a><a href="#impressum">{copy.legalTitle}</a><a href="#top">{copy.footerTop}</a></div>
        <small>{copy.footerCopyright}</small>
      </footer>
    </main>
  );
}
