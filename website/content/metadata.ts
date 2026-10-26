import type { Metadata, Viewport } from "next";

const copy = {
  de: {
    title: "nextStop – Deine Pause. Deine Entscheidung.",
    socialTitle: "Deine Pause. Deine Entscheidung.",
    description: "Laden und Essen bei einem gemeinsamen Stopp: Bereite deine Fahrt auf dem iPhone vor und finde unterwegs mit CarPlay den Ladepark, der zu deiner Pause passt.",
    socialDescription: "Dein Auto lädt, du machst Pause. nextStop findet Ladeparks mit deiner gewünschten Restaurantkette in der Nähe.",
    twitterDescription: "Dein nächster Stopp nach deinen Bedürfnissen: Ladeparkgröße, Leistung und auf Wunsch ein Restaurant.",
    imageAlt: "nextStop – Dein Auto lädt. Du machst Pause. Laden und Essen bei einem gemeinsamen Stopp.",
    path: "/", image: "/og.png", openGraphLocale: "de_DE",
  },
  en: {
    title: "nextStop – Your break. Your choice.",
    socialTitle: "Your break. Your choice.",
    description: "Charge and eat at one stop: prepare your trip on iPhone, then use CarPlay to find a charging stop that fits your plans for a break.",
    socialDescription: "Your car charges. You take a break. nextStop finds charging locations near your preferred restaurant chain.",
    twitterDescription: "Your next stop, your preferences: charging points, charging power and, if you want, a restaurant nearby.",
    imageAlt: "nextStop – Your car charges. You take a break. Charge and eat at one stop.",
    path: "/en/", image: "/og-en.png", openGraphLocale: "en_GB",
  },
};

export function websiteMetadata(locale: keyof typeof copy): Metadata {
  const text = copy[locale];
  return {
    metadataBase: new URL("https://nextstop.tech"),
    title: text.title,
    description: text.description,
    applicationName: "nextStop",
    alternates: { canonical: text.path, languages: { de: "/", en: "/en/", "x-default": "/" } },
    icons: { icon: "/app-icon.png", apple: "/app-icon.png" },
    openGraph: {
      title: text.socialTitle,
      description: text.socialDescription,
      url: text.path,
      siteName: "nextStop",
      locale: text.openGraphLocale,
      alternateLocale: locale === "de" ? "en_GB" : "de_DE",
      type: "website",
      images: [{ url: text.image, width: 1200, height: 630, alt: text.imageAlt }],
    },
    twitter: {
      card: "summary_large_image",
      title: text.socialTitle,
      description: text.twitterDescription,
      images: [text.image],
    },
  };
}

export const viewport: Viewport = {
  themeColor: "#10271f", colorScheme: "light", width: "device-width", initialScale: 1,
};
