import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://nextstop.tech"),
  title: "nextStop – Deine Pause. Deine Entscheidung.",
  description:
    "Wähle deinen nächsten Stopp nach deinen Bedürfnissen: passende Ladeparks entlang deiner Route, auf Wunsch mit deiner bevorzugten Restaurantkette in Laufnähe.",
  applicationName: "nextStop",
  alternates: { canonical: "/" },
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
  openGraph: {
    title: "Deine Pause. Deine Entscheidung.",
    description:
      "Du bestimmst, was deine Pause braucht. nextStop findet passende Ladeparks entlang deiner Route – auf Wunsch mit Restaurant.",
    url: "/",
    siteName: "nextStop",
    locale: "de_DE",
    type: "website",
    images: [
      {
        url: "/og.png",
        width: 1731,
        height: 909,
        alt: "nextStop – Hunger auf der Strecke? Pause machen. Weiterkommen.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "nextStop – Deine Pause. Deine Entscheidung.",
    description:
      "Dein nächster Stopp nach deinen Bedürfnissen: Ladeparkgröße, Leistung und auf Wunsch ein Restaurant.",
    images: ["/og.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#10271f",
  colorScheme: "light",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="de">
      <body>{children}</body>
    </html>
  );
}
