import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://nextstop.tech"),
  title: "nextStop – Ladepause und Essenspause verbinden",
  description:
    "Finde bis zu fünf passende Ladeparks entlang deiner Route – auf Wunsch mit deiner bevorzugten Restaurantkette in Laufnähe.",
  applicationName: "nextStop",
  alternates: { canonical: "/" },
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
  openGraph: {
    title: "Hunger auf der Strecke? Finde den Stopp, der beides kann.",
    description:
      "nextStop verbindet Ladepause und Essenspause entlang deiner echten Route.",
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
    title: "nextStop – Pause machen. Weiterkommen.",
    description:
      "Passende Ladeparks mit Restaurant entlang deiner echten Route.",
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
