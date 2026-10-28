<!-- Sistem → Sunucu: the server's facts (live.kaynaklar: name, system, kernel, Obhut's version and build,
     uptime, Tailscale and internet addresses, Konsol's address, the user area; Erişim's Tailscale summary: the
     device's name, the client version, whether it is offered as an exit node, DD-288) and "Yeniden başlat" (DD-246),
     after the typed word and only from the tailnet. The server reboots a few seconds after answering; the
     page then waits, asks for the server's facts every 2 s and loads itself again once the server answers
     after it went away (or with a shorter uptime). -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from "vue";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import { reboot } from "../../api/sistem";
import { getJson } from "../../api/http";
import { YOLLAR } from "../../api/sema";
import { live } from "../../live";
import { internetChannel, loadSession } from "./session";
import { UNKNOWN, shortVersion, uptime } from "../../format";

void loadSession();

const k = computed(() => live.kaynaklar);
const text = (v: unknown) => (typeof v === "string" && v ? v : UNKNOWN);
const join = (...values: unknown[]) => values.filter((v): v is string => typeof v === "string" && v !== "").join(" · ") || UNKNOWN;
const ts = computed(() => live.erisim?.ozet.tailscale ?? null);
/** Whether this server is offered as an exit node; approving it is the Tailscale admin console's. */
const exitNode = (v: boolean | null | undefined) =>
  v === true ? "Sunuluyor (yönetim panelinde onaylanınca kullanılır)" : v === false ? "Sunulmuyor" : UNKNOWN;
const facts = computed(() => {
  const s = k.value;
  if (!s) return null;
  return [
    { id: "host", label: "Sunucu", value: text(s.host), mono: false },
    { id: "os", label: "Sistem", value: text(s.os), mono: false },
    { id: "kernel", label: "Çekirdek", value: text(s.kernel), mono: true },
    { id: "version", label: "Obhut", value: s.surum || shortVersion(s.version), mono: false },
    { id: "build", label: "Yapı", value: text(s.version), mono: true },
    { id: "uptime", label: "Açık kalma", value: uptime(s.uptime), mono: false },
    { id: "tailscale", label: "Tailscale", value: join(s.net?.tailscale, s.net?.tailscale6), mono: true },
    { id: "ts-name", label: "Tailscale adı", value: text(ts.value?.ad), mono: true },
    { id: "ts-version", label: "Tailscale istemcisi", value: text(ts.value?.surum), mono: false },
    { id: "ts-exit", label: "Çıkış düğümü", value: exitNode(ts.value?.cikis_dugumu), mono: false },
    { id: "wan", label: "İnternet", value: join(s.net?.wan, s.net?.wan6) + (s.net?.iface ? ` (${s.net.iface})` : ""), mono: true },
    { id: "panel", label: "Konsol adresi", value: s.domain ? "panel." + s.domain : UNKNOWN, mono: true },
    { id: "root", label: "Kullanıcı alanı", value: text(s.root), mono: true },
  ];
});

// ---- the reboot
const lock = computed(() => (internetChannel.value ? "Yeniden başlatma yalnız Tailscale adresinden istenir." : ""));
const askOpen = ref(false);
const typed = ref(false);
const sending = ref(false);
const sendError = ref("");
type Phase = "" | "bekliyor" | "kapali" | "acildi" | "gec";
const phase = ref<Phase>("");
const delay = ref(0);
let timer: number | undefined;
let since = 0;
let wentAway = false;
let uptimeBefore: number | null = null;
let alive = true;

function ask(): void {
  sendError.value = "";
  askOpen.value = true;
}

async function confirm(): Promise<void> {
  if (!typed.value || sending.value) return;
  sending.value = true;
  sendError.value = "";
  try {
    const answer = await reboot();
    askOpen.value = false;
    delay.value = answer.sure;
    uptimeBefore = typeof k.value?.uptime === "number" ? k.value.uptime : null;
    wentAway = false;
    since = Date.now();
    phase.value = "bekliyor";
    poll();
  } catch (err) {
    sendError.value = err instanceof Error ? err.message : String(err);
  } finally {
    sending.value = false;
  }
}

/** Asks for the server's facts until it has come back: answered after a failed read, or with a shorter
    uptime (a reboot faster than the reads). */
function poll(): void {
  clearTimeout(timer);
  if (!alive) return;
  timer = window.setTimeout(async () => {
    try {
      const facts = (await getJson(YOLLAR.kaynaklar)) as { uptime?: unknown } | null;
      const up = typeof facts?.uptime === "number" ? facts.uptime : null;
      if (!alive) return;
      if (wentAway || (uptimeBefore !== null && up !== null && up < uptimeBefore)) {
        phase.value = "acildi";
        timer = window.setTimeout(() => location.reload(), 1500);
        return;
      }
    } catch {
      wentAway = true;
      if (phase.value === "bekliyor") phase.value = "kapali";
    }
    if (Date.now() - since > 10 * 60_000 && phase.value !== "acildi") phase.value = "gec";
    poll();
  }, 2000);
}

const waitText = computed(() => {
  switch (phase.value) {
    case "bekliyor":
      return `Sunucu ${delay.value} saniye içinde yeniden başlıyor; Konsol birkaç dakika ulaşılamaz.`;
    case "kapali":
      return "Sunucu yeniden başlıyor; yanıt vermesi bekleniyor…";
    case "acildi":
      return "Sunucu yeniden açıldı; sayfa yenileniyor…";
    case "gec":
      return "Sunucu on dakikadır yanıt vermiyor. Tailscale'den ya da SSH ile denetleyin; sayfa beklemeyi sürdürüyor.";
    default:
      return "";
  }
});

onBeforeUnmount(() => {
  alive = false;
  clearTimeout(timer);
});
</script>

<template>
  <div class="system-tab" data-testid="server-tab">
    <section class="card" aria-labelledby="sunucu-baslik" data-testid="server-facts">
      <h2 id="sunucu-baslik" class="card-title">Sunucu</h2>
      <dl v-if="facts" class="facts">
        <template v-for="f in facts" :key="f.id">
          <dt>{{ f.label }}</dt>
          <dd :class="{ mono: f.mono }" :data-bilgi="f.id">{{ f.value }}</dd>
        </template>
      </dl>
      <EmptyState v-else title="Sunucu bilgisi bekleniyor" text="Sunucu yanıt verince burada görünür." icon="server" />
    </section>

    <section class="card" aria-labelledby="yeniden-baslik" data-testid="reboot">
      <div class="card-head">
        <h2 id="yeniden-baslik" class="card-title">Yeniden başlat</h2>
        <div class="card-actions">
          <button type="button" class="btn btn-danger-quiet" :disabled="Boolean(lock) || phase !== ''" :aria-describedby="lock ? 'yeniden-kilit' : undefined" data-testid="reboot-open" @click="ask">
            <Icon name="power" :size="16" />Yeniden başlat…
          </button>
        </div>
      </div>
      <p class="card-text">Tüm servisler ve uygulamalar durur; sunucu birkaç dakika içinde geri gelir. Süren aktarımlar ve WebDAV bağlantıları kesilir.</p>
      <p v-if="lock" id="yeniden-kilit" class="notice" role="note" data-testid="reboot-lock"><Icon name="lock" class="notice-icon" /><span>{{ lock }}</span></p>
      <p class="sr-only" role="status">{{ waitText }}</p>
      <p v-if="phase" class="reboot-wait" :class="'reboot-' + phase" aria-hidden="true" data-testid="reboot-wait" :data-asama="phase">
        <span v-if="phase !== 'acildi'" class="spinner" aria-hidden="true"></span>
        <Icon v-else name="check" :size="18" />
        <span>{{ waitText }}</span>
      </p>
    </section>

    <Modal :open="askOpen" variant="sheet" title="Sunucu yeniden başlatılsın mı?" :description="k?.host ?? ''" @close="askOpen = false">
      <ul class="modal-list">
        <li><Icon name="refresh" :size="18" /><span>Tüm servisler ve uygulamalar durur; sunucu birkaç dakika içinde geri gelir.</span></li>
        <li><Icon name="info" :size="18" /><span>Süren aktarımlar ve WebDAV bağlantıları kesilir.</span></li>
      </ul>
      <ConfirmWord v-model:confirmed="typed" />
      <p v-if="sendError" class="form-error" role="alert" data-testid="reboot-error">{{ sendError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="sending" @click="askOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!typed || sending" data-testid="reboot-go" @click="confirm">
          {{ sending ? "Gönderiliyor…" : "Yeniden başlat" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
