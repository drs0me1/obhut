// Konsol's live events (DD-258): GET /api/konsol/olaylar, a text/event-stream read with fetch() because the
// backend's gate wants X-Konsol on every /api/* request and EventSource cannot send a header. One stream
// lives as long as the page. The server sends "kapat" and ends each stream after about ten minutes, then
// the next one starts at once; a stream that ends or fails otherwise is retried after the server's
// "retry:" value, doubling on repeated failures up to 30 s. 401 goes to the sign-in page; 404, 503 or a
// browser without ReadableStream leave the caller to poll the GET endpoints instead.
import { YOLLAR } from "./sema";
import { KONSOL_HEADERS, goToSignIn } from "./http";

export interface SseMessage {
  event: string;
  data: string;
}

/** The WHATWG event-stream interpretation: lines end in CRLF, LF or CR; a blank line ends a message;
    lines starting with ":" are comments (the server's heartbeats). */
// A message larger than this ends the stream (the server's are a few kilobytes).
const MAX_MESSAGE = 1 << 20;

export class SseParser {
  private rest = "";
  private data: string[] = [];
  private size = 0;
  private type = "";
  retry: number | null = null;
  lastId = "";

  push(chunk: string): SseMessage[] {
    const out: SseMessage[] = [];
    let text = this.rest + chunk;
    if (text.length + this.size > MAX_MESSAGE) throw new Error("Olay akışında aşırı büyük ileti.");
    // A CR at the end may be the first half of a CRLF split across chunks.
    let carry = "";
    if (text.endsWith("\r")) {
      carry = "\r";
      text = text.slice(0, -1);
    }
    const lines = text.split(/\r\n|\r|\n/);
    this.rest = (lines.pop() ?? "") + carry;
    for (const line of lines) this.line(line, out);
    return out;
  }

  private line(line: string, out: SseMessage[]): void {
    if (line === "") {
      if (this.data.length) out.push({ event: this.type || "message", data: this.data.join("\n") });
      this.data = [];
      this.size = 0;
      this.type = "";
      return;
    }
    if (line.startsWith(":")) return;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") this.type = value;
    else if (field === "data") {
      this.data.push(value);
      this.size += value.length + 1;
    }
    else if (field === "id") {
      if (!value.includes("\0")) this.lastId = value;
    } else if (field === "retry" && /^\d+$/.test(value)) this.retry = Number(value);
  }
}

export interface StreamHooks {
  /** A reply is streaming (HTTP 200). */
  open(): void;
  /** One parsed event; `data` is the JSON value of its data lines. */
  event(name: string, data: unknown): void;
  /** The stream ended or failed; `failures` counts consecutive failures (0 after a planned close). */
  lost(failures: number): void;
  /** No stream here: the caller polls instead. */
  unavailable(reason: string): void;
}

const DEFAULT_RETRY_MS = 3000;
const MAX_WAIT_MS = 30000;
// A planned close ("kapat") reconnects at once only after a stream that lasted; a server that keeps
// closing right away is treated like a failure, so it is not asked again in a tight loop.
const PLANNED_MIN_MS = 5000;

export function openEvents(hooks: StreamHooks): () => void {
  const controller = new AbortController();
  let stopped = false;
  const sleep = (ms: number) =>
    new Promise<void>((resolve) => {
      const wake = () => {
        clearTimeout(timer);
        controller.signal.removeEventListener("abort", wake);
        resolve();
      };
      const timer = setTimeout(wake, ms);
      controller.signal.addEventListener("abort", wake);
    });

  const run = async () => {
    let retry = DEFAULT_RETRY_MS;
    let failures = 0;
    while (!stopped) {
      let planned = false;
      let startedAt = 0;
      let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
      try {
        if (typeof ReadableStream === "undefined" || typeof TextDecoder === "undefined") {
          hooks.unavailable("Tarayıcı akışı okuyamıyor.");
          return;
        }
        const res = await fetch(YOLLAR.olaylar, {
          headers: { ...KONSOL_HEADERS, Accept: "text/event-stream" },
          credentials: "same-origin",
          cache: "no-store",
          signal: controller.signal,
        });
        if (res.status === 401) {
          stopped = true;
          goToSignIn();
          return;
        }
        if (res.status === 404 || res.status === 503) {
          await res.body?.cancel().catch(() => undefined);
          hooks.unavailable(`HTTP ${res.status}`);
          return;
        }
        if (!res.ok) {
          await res.body?.cancel().catch(() => undefined);
          throw new Error(`HTTP ${res.status}`);
        }
        if (!res.body || typeof res.body.getReader !== "function") {
          hooks.unavailable("Tarayıcı akışı okuyamıyor.");
          return;
        }
        reader = res.body.getReader();
        const decoder = new TextDecoder();
        const parser = new SseParser();
        startedAt = Date.now();
        hooks.open();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value && value.length) failures = 0;
          for (const message of parser.push(decoder.decode(value, { stream: true }))) {
            if (message.event === "kapat") planned = true;
            let data: unknown;
            try {
              data = JSON.parse(message.data);
            } catch {
              continue;
            }
            try {
              hooks.event(message.event, data);
            } catch (err) {
              // A page that cannot show one event keeps the stream.
              console.error(err);
            }
          }
          if (parser.retry !== null) retry = Math.min(Math.max(parser.retry, 250), MAX_WAIT_MS);
        }
      } catch {
        // A network error, an unexpected status or an oversized message: retried below.
      } finally {
        reader?.cancel().catch(() => undefined);
      }
      if (stopped) return;
      if (planned && Date.now() - startedAt >= PLANNED_MIN_MS) {
        hooks.lost(0);
        continue;
      }
      failures += 1;
      hooks.lost(failures);
      await sleep(Math.min(MAX_WAIT_MS, retry * 2 ** Math.min(failures - 1, 8)));
    }
  };
  void run();
  return () => {
    stopped = true;
    controller.abort();
  };
}
