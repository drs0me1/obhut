// A new Konsol build while this page is open (DD-280). A re-run of the installer from the terminal, or an update
// started in another tab, replaces the files this page loaded, but the page keeps running the code it has. The page
// notes its own files' identity when it starts: the ETag of its script and its style sheet, asked with HEAD and
// never from a cache. When the server's build number changes it looks again every few seconds until the files
// themselves change (the installer writes the number in stage 3 and the files only in stage 6) or twenty minutes
// pass, and once more whenever the tab comes back into view (a re-run that kept the number). An install that did
// not touch Konsol's files changes nothing here.
import { ref, watch } from "vue";
import { live } from "./live";

const CHECK_MS = 5000;
const GIVE_UP_MS = 20 * 60 * 1000;

/** True once the files this page runs have been replaced on the server. */
export const newBuild = ref(false);

/** This page's own script and style sheet (Vite's names, whatever they are). */
function files(): string[] {
  const urls = [
    document.querySelector<HTMLScriptElement>('script[type="module"][src]')?.src,
    document.querySelector<HTMLLinkElement>('link[rel="stylesheet"][href]')?.href,
  ];
  return urls.filter((u): u is string => typeof u === "string" && u !== "" && new URL(u).origin === location.origin);
}

/** The files' identity as the server answers now; null when it cannot be read (then nothing is watched). */
async function identity(): Promise<string | null> {
  const urls = files();
  if (!urls.length) return null;
  try {
    const tags = await Promise.all(
      urls.map(async (url) => {
        const reply = await fetch(url, { method: "HEAD", cache: "no-store", credentials: "same-origin" });
        if (!reply.ok) throw new Error(String(reply.status));
        return reply.headers.get("ETag") ?? `${reply.headers.get("Last-Modified") ?? ""}|${reply.headers.get("Content-Length") ?? ""}`;
      }),
    );
    return tags.join(" ");
  } catch {
    return null;
  }
}

let loaded: string | null = null;
let timer: number | undefined;
let until = 0;

async function look(): Promise<void> {
  if (newBuild.value || loaded === null) return;
  const now = await identity();
  if (now === null || now === loaded) return;
  newBuild.value = true;
  clearInterval(timer);
  timer = undefined;
}

function lookForAWhile(): void {
  until = Date.now() + GIVE_UP_MS;
  if (timer !== undefined) return;
  timer = window.setInterval(() => {
    if (Date.now() <= until) void look();
    else {
      clearInterval(timer);
      timer = undefined;
    }
  }, CHECK_MS);
  void look();
}

/** Notes this page's files and starts watching for new ones (the shell, once). */
export async function watchBuild(): Promise<void> {
  loaded = await identity();
  if (loaded === null) return;
  let first = "";
  watch(
    () => live.kaynaklar?.version ?? "",
    (version) => {
      if (!version || newBuild.value) return;
      if (!first) first = version;
      else if (version !== first) lookForAWhile();
    },
    { immediate: true },
  );
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void look();
  });
}
