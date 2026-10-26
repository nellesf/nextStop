import { websiteMetadata, viewport } from "../../../content/metadata";
import "../../globals.css";

export const metadata = websiteMetadata("en");
export { viewport };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
