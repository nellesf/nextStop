export type ResultScreenshot = {
  src: string;
  alt: string;
  caption: string;
};

// Add only imported, visually reviewed captures. Empty collections render no
// gallery, so the page never references files that a capture has not produced.
// Planned sequence: iPhone results, restaurant place, charging place; CarPlay
// results, result actions, charging operators, restaurant place, charging place.
// Both platforms' final two place views belong to Apple Maps, not nextStop.
export const iphoneResultScreenshots: ResultScreenshot[] = [];
export const carplayResultScreenshots: ResultScreenshot[] = [];
