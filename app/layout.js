import "./globals.css";

export const metadata = {
  title: "AegisHook Security Portal",
  description: "Reactive Safety as a Service for Aegis-protected pools"
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body suppressHydrationWarning>{children}</body>
    </html>
  );
}
