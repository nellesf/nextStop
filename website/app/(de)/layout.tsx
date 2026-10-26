import { websiteMetadata, viewport } from "../../content/metadata";
import "../globals.css";

export const metadata = websiteMetadata("de");
export { viewport };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="de">
      <body>{children}</body>
    </html>
  );
}
