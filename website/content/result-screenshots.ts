export type ResultScreenshot = {
  src: string;
  alt: string;
  caption: string;
  width?: number;
  height?: number;
};

// Add only imported, visually reviewed captures. Empty collections render no
// gallery, so the page never references files that a capture has not produced.
// Reviewed six-screen sequence: iPhone results, restaurant place, charging place;
// CarPlay results, result actions, charging operators. The two iPhone place
// views belong to Apple Maps; the remaining four screens belong to nextStop.
export const iphoneResultScreenshots: ResultScreenshot[] = [
  {
    src: "/screenshots/iphone-results.png",
    alt: "nextStop auf dem iPhone: Ergebnisliste mit Restaurants, Fahrstrecken und Ladeanbietern",
    caption: "nextStop · iPhone · Ergebnisse",
  },
  {
    src: "/screenshots/iphone-restaurant-place.png",
    alt: "Apple Maps auf dem iPhone: ausgewähltes McDonald's-Restaurant mit Ortskarte",
    caption: "Apple Maps · iPhone · Restaurant",
  },
  {
    src: "/screenshots/iphone-charging-place.png",
    alt: "Apple Maps auf dem iPhone: ausgewählter Ladestandort EDEKA Versorgungsgesellschaft",
    caption: "Apple Maps · iPhone · Ladestandort",
  },
];

export const carplayResultScreenshots: ResultScreenshot[] = [
  {
    src: "/screenshots/carplay-wide/carplay-results.png",
    width: 1920,
    height: 720,
    alt: "nextStop in CarPlay: passende Ladestopps auf der Karte, nach Fahrstrecke sortiert",
    caption: "nextStop · CarPlay · Ergebnisse",
  },
  {
    src: "/screenshots/carplay-wide/carplay-result-actions.png",
    width: 1920,
    height: 720,
    alt: "nextStop in CarPlay: Restaurant oder Ladeanbieter desselben Pausenstopps als Ziel öffnen",
    caption: "nextStop · CarPlay · Dein Ziel am Stopp",
  },
  {
    src: "/screenshots/carplay-wide/carplay-charging-places.png",
    width: 1920,
    height: 720,
    alt: "nextStop in CarPlay: Ladeanbieter beim gewählten Restaurant mit Öffnen in Apple Maps",
    caption: "nextStop · CarPlay · Ladeanbieter beim Restaurant",
  },
];
