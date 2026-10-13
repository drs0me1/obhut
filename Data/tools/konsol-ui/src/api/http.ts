// Requests to Konsol's root backend. Every /api/* request carries X-Konsol (the CSRF rule, DD-147/180)
// and the session cookie; nothing is cached. A 401 means the internet session ended: the browser goes to
// the sign-in page, which returns to this interface and the same view afterwards (geri=yeni; DD-194,
// DD-205, DD-259). Any other failure is an ApiError carrying the backend's own message.
import type { Hata } from "./sema";

export class ApiError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

let leaving = false;

export function goToSignIn(): void {
  if (leaving) return;
  leaving = true;
  location.replace("/giris.html?geri=yeni" + (location.hash.startsWith("#/") ? location.hash : ""));
}

export const KONSOL_HEADERS: Readonly<Record<string, string>> = Object.freeze({ "X-Konsol": "1" });

const isHata = (body: unknown): body is Hata =>
  typeof body === "object" && body !== null && typeof (body as { error?: unknown }).error === "string";

async function reply(res: Response): Promise<unknown> {
  if (res.status === 401) {
    goToSignIn();
    throw new ApiError(401, "Oturum gerekli; yeniden giriş yapın.");
  }
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  if (!res.ok) throw new ApiError(res.status, isHata(body) ? body.error : `Sunucu yanıtı: HTTP ${res.status}`);
  return body;
}

export async function getJson(path: string): Promise<unknown> {
  return reply(await fetch(path, { headers: KONSOL_HEADERS, credentials: "same-origin", cache: "no-store" }));
}

/** POST with a JSON body; the backend refuses any other content type (body_json). */
export async function postJson(path: string, body: unknown): Promise<unknown> {
  return reply(
    await fetch(path, {
      method: "POST",
      headers: { ...KONSOL_HEADERS, "Content-Type": "application/json" },
      credentials: "same-origin",
      cache: "no-store",
      body: JSON.stringify(body),
    }),
  );
}
