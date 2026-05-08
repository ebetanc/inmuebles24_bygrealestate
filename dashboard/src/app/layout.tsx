import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { Sidebar } from "@/components/sidebar";
import { Topbar } from "@/components/topbar";

const inter = Inter({
  variable: "--font-sans",
  subsets: ["latin"],
  weight: ["300", "400", "500", "600", "700", "800"],
});

export const metadata: Metadata = {
  title: "BYG Real Estate — Dashboard",
  description: "Sistema de gestion de leads 24/7",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es" className={`${inter.variable} h-full antialiased`}>
      <body className="min-h-full bg-[#F8FAFC] text-[#1E293B]" style={{ fontFamily: "'Inter', sans-serif" }}>
        <Sidebar />
        <div className="ml-[260px] flex min-h-screen flex-col">
          <Topbar />
          <main className="flex-1 p-7">
            <div className="animate-fade-in">{children}</div>
          </main>
        </div>
      </body>
    </html>
  );
}
