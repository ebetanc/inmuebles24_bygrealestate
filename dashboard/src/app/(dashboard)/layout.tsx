import { Sidebar } from "@/components/sidebar";
import { Topbar } from "@/components/topbar";

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <Sidebar />
      <div className="ml-[260px] flex min-h-screen flex-col">
        <Topbar />
        <main className="flex-1 p-7">
          <div className="animate-fade-in">{children}</div>
        </main>
      </div>
    </>
  );
}
