import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

export async function middleware(request: NextRequest) {
  const session = request.cookies.get("dashboard_session")?.value;

  if (!session) {
    return NextResponse.redirect(new URL("/login", request.url));
  }

  const password = process.env.DASHBOARD_PASSWORD || "";
  const encoder = new TextEncoder();
  const data = encoder.encode(`inmobiliaria24:${password}`);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const expectedToken = hashArray
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (session !== expectedToken) {
    const response = NextResponse.redirect(new URL("/login", request.url));
    response.cookies.delete("dashboard_session");
    return response;
  }

  return NextResponse.next();
}

export const config = {
  matcher: [
    "/((?!login|_next/static|_next/image|favicon\\.ico|api/auth).*)",
  ],
};
