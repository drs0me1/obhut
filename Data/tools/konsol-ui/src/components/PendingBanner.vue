<!-- A settings change waiting on the server (DD-156's transaction): shown on every page until it is confirmed
     or rolled back. While it awaits confirmation the banner counts down locally from the server's `seconds`
     (re-sent about once a second) and offers "Onayla" and "Geri al" right here. Confirmation comes only from a
     Tailscale device (DD-195), and a local domain change only from its new address (http://panel.<new>): the
     banner says so instead of offering it. A rollback that failed five times ("stuck") can be retried or, with
     the typed word, discarded. The result stays as a line for a few seconds. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { Icon } from "./icons";
import ConfirmWord from "./ui/ConfirmWord.vue";
import Modal from "./ui/Modal.vue";
import { live, setPending } from "../live";
import { confirmChange, discardChange, rollBackChange } from "../api/erisim";
import { tailnetKonsol } from "../links";
import { countdown } from "../format";

const now = ref(Date.now());
let ticker: number | undefined;

const change = computed(() => live.bekleyen ?? null);
const awaiting = computed(() => change.value?.phase === "awaiting" && typeof change.value.seconds === "number" && Number.isFinite(change.value.seconds));

watch(
  awaiting,
  (on) => {
    if (on && ticker === undefined) {
      now.value = Date.now();
      ticker = window.setInterval(() => (now.value = Date.now()), 1000);
    } else if (!on && ticker !== undefined) {
      clearInterval(ticker);
      ticker = undefined;
    }
  },
  { immediate: true },
);
onBeforeUnmount(() => {
  clearInterval(ticker);
  clearTimeout(resultTimer);
});

// A new change (applied from a form further down the page): bring the banner into view, focus stays put.
const banner = ref<HTMLElement | null>(null);
watch(
  () => change.value?.id,
  (id, before) => {
    if (!id || id === before) return;
    void nextTick(() => {
      const el = banner.value;
      if (el && el.getBoundingClientRect().top < 0) el.scrollIntoView({ block: "nearest" });
    });
  },
);

const remaining = computed(() => {
  const c = change.value;
  if (!c || !awaiting.value) return 0;
  return Math.max(0, c.seconds - Math.floor((now.value - live.bekleyenAt) / 1000));
});

const detail = computed(() => {
  const c = change.value;
  switch (c?.phase) {
    case "applying":
      return "Değişiklik sunucuda uygulanıyor…";
    case "committed":
      return "Değişiklik kaydedildi.";
    case "rollback":
      return c.attempts
        ? `Geri alma denendi, tamamlanamadı: ${c.error || "bilinmiyor"}. ${c.retry_in ?? 0} sn sonra yeniden denenecek (${c.attempts}/5).`
        : "Önceki ayarlar geri yükleniyor…";
    case "stuck":
      return `Geri alma tamamlanamadı (${c.attempts ?? 5} deneme). Son hata: ${c.error || "bilinmiyor"}. Sunucu kendiliğinden yeniden denemez; kurulum ve uygulama işlemleri beklemede.`;
    default:
      return "";
  }
});

// Where confirmation is possible: over Tailscale (http), and for a domain change at its new address.
const internetChannel = location.protocol === "https:";
const domain = computed(() => change.value?.domain ?? null);
const wrongAddress = computed(() => Boolean(domain.value && location.hostname !== "panel." + domain.value.new));
const newAddress = computed(() => (domain.value ? tailnetKonsol(domain.value.new, "#/erisim?sekme=adresler") : ""));
const oldAddress = computed(() => (domain.value ? tailnetKonsol(domain.value.old, "#/erisim?sekme=adresler") : ""));
const tailnetAddress = computed(() => (live.kaynaklar?.domain ? tailnetKonsol(live.kaynaklar.domain) : ""));

const busy = ref(false);
const error = ref("");
const result = ref("");
let resultTimer: number | undefined;

function say(text: string): void {
  result.value = text;
  clearTimeout(resultTimer);
  resultTimer = window.setTimeout(() => (result.value = ""), 8000);
}

async function act(kind: "onayla" | "geri-al"): Promise<void> {
  const c = change.value;
  if (!c || busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    if (kind === "onayla") await confirmChange(c.id);
    else await rollBackChange(c.id);
    setPending(null);
    say(kind === "onayla" ? "Ayarlar kalıcı olarak kaydedildi." : "Önceki ayarlar geri yüklendi.");
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  } finally {
    busy.value = false;
  }
}

const canConfirm = computed(() => awaiting.value && remaining.value > 0 && !internetChannel && !wrongAddress.value && !busy.value);

const discardOpen = ref(false);
const discardWord = ref(false);
const discardError = ref("");
function askDiscard(): void {
  discardWord.value = false;
  discardError.value = "";
  discardOpen.value = true;
}
async function discard(): Promise<void> {
  const c = change.value;
  if (!c || !discardWord.value || busy.value) return;
  busy.value = true;
  discardError.value = "";
  try {
    await discardChange(c.id);
    discardOpen.value = false;
    setPending(null);
    say("Takılan işlem bırakıldı; kaydedilmiş ayarlar için kurulumu yeniden çalıştırın.");
  } catch (err) {
    discardError.value = err instanceof Error ? err.message : String(err);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="pending-slot" aria-live="polite">
    <section v-if="change" ref="banner" class="pending" aria-labelledby="bekleyen-baslik" :data-phase="change.phase">
      <span class="pending-icon"><Icon :name="change.phase === 'stuck' ? 'alert' : 'clock'" /></span>
      <div class="pending-text">
        <strong id="bekleyen-baslik">Bekleyen bir ayar değişikliği var</strong>
        <span class="pending-detail" aria-live="off">
          <template v-if="awaiting && remaining > 0">
            <span class="pending-count" data-testid="countdown">{{ countdown(remaining) }}</span> içinde onaylanmazsa önceki ayarlar geri yüklenir.
          </template>
          <template v-else-if="awaiting">Süre doldu; önceki ayarlar geri yükleniyor…</template>
          <template v-else>{{ detail }}</template>
        </span>
        <span v-if="awaiting && internetChannel" class="pending-note" data-testid="pending-internet">
          Onay yalnız Tailscale'e bağlı bir cihazdan verilir: Konsol'u Tailscale adresinden açın<template v-if="tailnetAddress"> (<a :href="tailnetAddress">{{ tailnetAddress }}</a>)</template>. Buradan geri alabilir ya da sürenin dolmasını bekleyebilirsiniz.
        </span>
        <span v-else-if="awaiting && domain && wrongAddress" class="pending-note" data-testid="pending-domain">
          Alan adı {{ domain.old }} → {{ domain.new }} değişiyor; yeni adresten onaylayın:
          <a :href="newAddress" target="_blank" rel="noopener">panel.{{ domain.new }}</a>. Tailscale yönetim panelindeki split DNS kaydını da yeni ada çevirin. Geri dönüş adresi:
          <a :href="oldAddress" target="_blank" rel="noopener">panel.{{ domain.old }}</a>.
        </span>
        <span v-if="error" class="pending-error" role="alert" data-testid="pending-error">{{ error }}</span>
      </div>
      <div v-if="change.phase === 'awaiting' || change.phase === 'applying'" class="pending-actions">
        <button type="button" class="btn btn-primary" :disabled="!canConfirm" data-testid="pending-confirm" @click="act('onayla')">
          {{ busy ? "Gönderiliyor…" : "Onayla" }}
        </button>
        <button type="button" class="btn btn-secondary" :disabled="busy || change.phase !== 'awaiting'" data-testid="pending-rollback" @click="act('geri-al')">Geri al</button>
      </div>
      <div v-else-if="change.phase === 'stuck'" class="pending-actions">
        <button type="button" class="btn btn-primary" :disabled="busy" data-testid="pending-retry" @click="act('geri-al')">Yeniden dene</button>
        <button type="button" class="btn btn-secondary" :disabled="busy" data-testid="pending-discard" @click="askDiscard">Bırak…</button>
      </div>
    </section>
    <p v-else-if="result" class="pending-result" role="status" data-testid="pending-result"><Icon name="check" :size="18" />{{ result }}</p>

    <Modal :open="discardOpen" variant="sheet" title="Takılan geri alma bırakılsın mı?" description="Sunucu önceki ayarları beş denemede geri yükleyemedi." @close="discardOpen = false">
      <ul class="modal-list">
        <li><Icon name="alert" :size="18" /><span>Bırakırsanız dosyalar şu anki hâlinde kalır ve bekleyen işlem silinir; kurulum ve uygulama işlemleri yeniden açılır.</span></li>
        <li><Icon name="refresh" :size="18" /><span>Kaydedilmiş (onaylanmış) ayarları yeniden uygulamak için ardından kurulumu çalıştırın.</span></li>
      </ul>
      <ConfirmWord v-model:confirmed="discardWord" />
      <p v-if="discardError" class="form-error" role="alert">{{ discardError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="busy" @click="discardOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!discardWord || busy" data-testid="discard-go" @click="discard">Bırak</button>
      </template>
    </Modal>
  </div>
</template>
