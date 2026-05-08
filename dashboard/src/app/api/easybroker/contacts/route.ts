import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const page = searchParams.get("page") || "1";
  const limit = searchParams.get("limit") || "20";

  const res = await fetch(
    `https://api.easybroker.com/v1/contact_requests?page=${page}&limit=${limit}`,
    {
      headers: {
        "X-Authorization": process.env.EASYBROKER_API_KEY!,
      },
      next: { revalidate: 60 },
    }
  );

  if (!res.ok) {
    return NextResponse.json({ error: "EasyBroker API error" }, { status: res.status });
  }

  const data = await res.json();
  return NextResponse.json(data);
}
