import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://nextstop.tech"),
  title: "nextStop – Deine Pause. Deine Entscheidung.",
  description:
    "Laden und Essen bei einem gemeinsamen Stopp: Bereite deine Fahrt auf dem iPhone vor und finde unterwegs mit CarPlay den Ladepark, der zu deiner Pause passt.",
  applicationName: "nextStop",
  alternates: { canonical: "/" },
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
  openGraph: {
    title: "Deine Pause. Deine Entscheidung.",
    description:
      "Dein Auto lädt, du machst Pause. nextStop findet Ladeparks mit deiner gewünschten Restaurantkette in der Nähe.",
    url: "/",
    siteName: "nextStop",
    locale: "de_DE",
    type: "website",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "nextStop – Dein Auto lädt. Du machst Pause. Laden und Essen bei einem gemeinsamen Stopp.",
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
