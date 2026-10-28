<!-- Erişim → Adresler (rebuild phases 4 and 5): every access row from Erişim's read model, the one home of how a port
     is reached. "Adresler": Konsol, Paylaşımlar and each application port with an address (its Caddy row), with
     its Tailscale name, Tailscale port, internet name and state. "Doğrudan portlar": each application port without an
     address, with its scope (Kapalı, Yalnız Tailscale, İnternet) and where it is reached. A row's panel opens under
     the row itself, one at a time (AccessRowPanel): a switch or a scope opens it with that change made (a closing
     goes straight to its plan, an opening that needs a value asks for it first); "Ayrıntı" opens it as it is and
     closes it again; "Adres aç" gives a raw TCP port a Tailscale name. The open panel is in the address
     (?satir=<row id>, ?kip=adres-ac), so Erişim's "Adres aç", Genel Bakış, the matrix, the firewall's locked rows,
     an application's page and a locked local name open it. While it applies, the table's controls wait. -->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import type { Tone } from "../../components/ui/types";
import AccessRowPanel, { type RowIntent, type RowMode, type RowOutcome } from "./AccessRowPanel.vue";
import { readNames } from "../../api/erisim";
import { SCOPE_CHOICES, addressCandidates, isAccessRow, portKey, rowOwner } from "../../access";
import { filesRoute } from "../../sections";
import { live, serverNow } from "../../live";
import { useQueryParam } from "../../query";
import { daysUntil } from "../../format";
import type { Adlar, AyarSonucu, Hizmet } from "../../api/sema";

// The local names: an address's Tailscale name must not take one of them.
const names = ref<Adlar | null>(null);
async function loadNames(): Promise<void> {
  try {
    names.value = await readNames();
  } catch {
    // The server checks the names again; the panel only cannot warn early.
  }
}
onMounted(() => void loadNames());
watch(() => live.ayarSurumu, () => void loadNames());

const locked = computed(() => Boolean(live.bekleyen));
/** An apply in the open panel: the table's controls wait until it ends. */
const busy = ref(false);
const hold = computed(() => locked.value || busy.value);
const e = computed(() => live.erisim);
const domain = computed(() => names.value?.alan || e.value?.alan || live.kaynaklar?.domain || "");
const tailscaleV4 = computed(() => live.erisim?.ozet.tailscale.ipv4 || live.kaynaklar?.net?.tailscale || "");
const wanV4 = computed(() => live.erisim?.ozet.internet.ipv4 || live.kaynaklar?.net?.wan || "");

// ---- the rows: the fixed ones first, then each application port as the server lists them
const accessRows = computed<Hizmet[]>(() => {
  const rows = (e.value?.hizmetler ?? []).filter(isAccessRow);
  const rank = (h: Hizmet) => (h.tur === "konsol" ? 0 : h.tur === "paylasim" ? 1 : 2);
  return rows.map((h, i) => [h, i] as const).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([h]) => h);
});
const addressRows = computed(() => accessRows.value.filter((h) => h.tur !== "uygulama" || h.satir?.tur === "adres"));
const rawRows = computed(() => accessRows.value.filter((h) => h.tur === "uygulama" && h.satir?.tur === "ham"));
const candidates = computed(() => addressCandidates(accessRows.value));

const keyOf = (h: Hizmet) => portKey(h.anahtar ?? "");
const subOf = (h: Hizmet) => {
  const k = keyOf(h);
  return h.tur === "uygulama" && k ? `${h.servis} · ${k.port}/${k.protokol.toUpperCase()}` : h.aciklama;
};
const tailName = (h: Hizmet) => {
  if (h.tur === "konsol") return `panel.${domain.value}`;
  if (h.tur === "paylasim") return h.web?.tail ? `paylas.${domain.value}` : "";
  return h.satir?.tur === "adres" ? `${h.satir.ad}.${domain.value}` : "";
};
const tsPortOf = (h: Hizmet) => (h.satir?.tur === "adres" ? h.satir.tailscale_portu : null);
/** Paylaşımlar' fixed Tailscale port, as Erişim reports it (its WebDAV listener on the Tailscale address). */
const shareTsPort = (h: Hizmet) => h.tailscale.adresler.find((a) => /:\d+$/.test(a)) ?? "";
const internetOn = (h: Hizmet) => (h.satir?.tur === "adres" ? Boolean(h.satir.internet) : Boolean(h.web?.enabled));
const internetName = (h: Hizmet) => (h.satir?.tur === "adres" ? h.satir.internet : h.web?.enabled ? h.web.domain : "");

/** A row's state in a word: its internet name's certificate, a warning, Tailscale, or this server only. */
function stateOf(h: Hizmet): { tone: Tone; text: string; note: string } {
  const c = h.internet;
  if (c.durum === "hata") return { tone: "warning", text: "Sorunlu", note: c.not || `A kaydı → ${wanV4.value}` };
  if (c.uyari) return { tone: "warning", text: c.uyari, note: "" };
  const host = internetName(h);
  if (host && c.durum === "acik") {
    const cert = e.value?.ozet.sertifikalar.find((s) => s.ad === host);
    if (cert?.durum === "gecerli" && cert.bitis) return { tone: "ok", text: `Sertifika · ${Math.max(0, daysUntil(cert.bitis, serverNow()))} gün`, note: "" };
    return { tone: "ok", text: "İnternette", note: "" };
  }
  if (h.tailscale.durum === "hata") return { tone: "danger", text: "Sorunlu", note: h.tailscale.not };
  if (h.tailscale.durum === "acik") return { tone: "ok", text: "Tailscale'de", note: "" };
  return { tone: "neutral", text: "Yalnız bu sunucu", note: "" };
}
/** Where a raw port is reached (its open cell's address), or "" while it is closed. */
const rawAddress = (h: Hizmet) => (h.satir?.tur === "ham" && h.satir.kapsam !== "kapali" ? h[h.satir.kapsam].adresler[0] ?? "" : "");
const rawPort = (h: Hizmet) => {
  const k = keyOf(h);
  if (!k || h.satir?.tur !== "ham") return "";
  return `${h.satir.port !== k.port ? `${h.satir.port} → ` : ""}${k.port}/${k.protokol.toUpperCase()}`;
};

// ---- the panel under its row: ?satir=<row id> (a deep link opens it too) and ?kip=adres-ac
const satir = useQueryParam<string>("satir", null, "");
const kip = useQueryParam<"" | "adres-ac">("kip", ["", "adres-ac"], "");
const mode = computed<RowMode>(() => (kip.value === "adres-ac" ? "adres-ac" : "duzenle"));
const intent = ref<RowIntent | null>(null);
const panelRow = computed(() => (satir.value ? accessRows.value.find((h) => h.id === satir.value) ?? null : null));
const missingRow = computed(() => Boolean(satir.value && e.value && !panelRow.value));
watch(satir, (id) => {
  if (!id) {
    kip.value = "";
    intent.value = null;
  }
});

function open(h: Hizmet, change: RowIntent | null = null, m: RowMode = "duzenle"): void {
  if (hold.value) return;
  note.value = "";
  intent.value = change;
  kip.value = m === "adres-ac" ? "adres-ac" : "";
  satir.value = h.id;
}
/** Whether a row's panel is open in this mode ("Ayrıntı" or "Adres aç"). */
const expanded = (h: Hizmet, m: RowMode = "duzenle") => satir.value === h.id && mode.value === m;
/** "Ayrıntı" and "Adres aç" open the row's panel, or close it when it is open already. */
function toggle(h: Hizmet, m: RowMode = "duzenle"): void {
  if (expanded(h, m) && !intent.value) closeRow();
  else open(h, null, m);
}
function pick(id: string): void {
  intent.value = null;
  satir.value = id;
}
/** Closing the panel gives the focus back to its row's "Ayrıntı". */
function closeRow(): void {
  const id = satir.value;
  satir.value = "";
  busy.value = false;
  void nextTick(() =>
    document.querySelector<HTMLElement>(`[data-testid="addresses"] tr[data-satir="${CSS.escape(id)}"] [data-eylem="ayrinti"]`)?.focus(),
  );
}
const PANEL_ID = "erisim-satir-paneli";

const note = ref("");
const OUTCOME: Record<RowOutcome, [string, string]> = {
  kaydedildi: ["Değişiklik kaydedildi.", "Değişiklik uygulandı; 60 saniye içinde yukarıdaki banttan onaylayın."],
  kaldirildi: ["Adres kaldırıldı.", "Adres kaldırıldı; 60 saniye içinde yukarıdaki banttan onaylayın."],
  acildi: ["Adres açıldı.", "Adres açıldı; 60 saniye içinde yukarıdaki banttan onaylayın."],
};
function rowApplied(result: AyarSonucu, outcome: RowOutcome): void {
  note.value = OUTCOME[outcome][result.pending ? 1 : 0];
  closeRow();
}
const panelProps = computed(() => ({
  row: panelRow.value,
  mode: mode.value,
  intent: intent.value,
  rows: accessRows.value,
  candidates: candidates.value,
  names: names.value,
  revision: e.value?.revizyon ?? "",
  domain: domain.value,
  wan: wanV4.value,
  tailscaleIp: tailscaleV4.value,
  locked: locked.value,
}));
const panelOn = {
  close: closeRow,
  mode: (m: RowMode) => (kip.value = m === "adres-ac" ? "adres-ac" : ""),
  pick,
  applied: rowApplied,
  busy: (on: boolean) => (busy.value = on),
};
</script>

<template>
  <div class="access-tab addresses" data-testid="addresses">
    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="action-note" aria-hidden="true" data-testid="addresses-note">{{ note }}</p>
    <p v-if="locked" class="notice" role="note" data-testid="addresses-locked">
      <Icon name="clock" class="notice-icon" />
      <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar yeni değişiklik uygulanamaz.</span>
    </p>
    <p v-if="missingRow" class="notice notice-warning" role="note" data-testid="row-missing">
      <Icon name="alert" class="notice-icon" /><span>Bu erişim satırı bulunamadı: <span class="mono">{{ satir }}</span></span>
    </p>
    <ul v-if="e?.hatalar.length" class="notice-list">
      <li v-for="(x, i) in e.hatalar" :key="i" class="warn-text">{{ x }}</li>
    </ul>

    <!-- the addresses (Caddy rows) -->
    <section class="card table-card" aria-labelledby="adres-baslik" data-testid="access-rows">
      <div class="card-head">
        <h2 id="adres-baslik" class="card-title">Adresler</h2>
        <span class="meter-note">Caddy satırları · değişiklik plan → uygula</span>
      </div>
      <div v-if="addressRows.length" class="table-wrap">
        <table class="data-table address-table">
          <thead>
            <tr>
              <th scope="col">Hizmet</th>
              <th scope="col">Tailscale adı</th>
              <th scope="col">Tailscale portu</th>
              <th scope="col">İnternet adı</th>
              <th scope="col">Durum</th>
              <th scope="col"><span class="sr-only">Eylemler</span></th>
            </tr>
          </thead>
          <tbody>
            <template v-for="h in addressRows" :key="h.id">
            <tr :data-satir="h.id" :class="{ 'row-current': satir === h.id }">
              <th scope="row" class="col-main">
                <strong>{{ rowOwner(h) }}</strong>
                <span class="cell-sub">{{ subOf(h) }}</span>
                <RouterLink v-if="h.tur === 'paylasim'" :to="filesRoute('paylasimlar')" class="cell-note" data-testid="share-folders">Klasör izinleri ve süreler: Dosyalar → Paylaşımlar</RouterLink>
              </th>
              <td data-label="Tailscale adı" data-hucre="tailscale">
                <span class="sw-cell">
                  <span v-if="h.tur === 'konsol'" class="lock-line"><Icon name="lock" :size="14" />Hep açık</span>
                  <Switch v-else :model-value="Boolean(tailName(h))" :label="`${rowOwner(h)} · Tailscale adı`" hide-label :disabled="hold"
                    @update:model-value="open(h, h.tur === 'paylasim' ? { kind: 'tail', on: $event } : { kind: 'kaldir' })" />
                  <span v-if="tailName(h)" class="mono cell-addr">{{ tailName(h) }}</span>
                </span>
              </td>
              <td data-label="Tailscale portu" data-hucre="ts-port">
                <span class="sw-cell">
                  <span v-if="h.tur === 'konsol'" class="muted">—</span>
                  <template v-else-if="h.tur === 'paylasim'">
                    <span class="lock-line"><Icon name="lock" :size="14" />Sabit</span>
                    <span v-if="shareTsPort(h)" class="mono cell-addr">{{ shareTsPort(h) }}</span>
                  </template>
                  <template v-else>
                    <Switch :model-value="tsPortOf(h) !== null" :label="`${rowOwner(h)} · Tailscale portu`" hide-label :disabled="hold"
                      @update:model-value="open(h, { kind: 'ts-port', on: $event })" />
                    <span v-if="tsPortOf(h) !== null" class="mono cell-addr">{{ tailscaleV4 ? `${tailscaleV4}:${tsPortOf(h)}` : `${tsPortOf(h)}/tcp` }}</span>
                  </template>
                </span>
              </td>
              <td data-label="İnternet adı" data-hucre="internet">
                <span class="sw-cell">
                  <Switch :model-value="internetOn(h)" :label="`${rowOwner(h)} · İnternet adı`" hide-label :disabled="hold"
                    @update:model-value="open(h, { kind: 'internet', on: $event })" />
                  <span v-if="internetName(h)" class="mono cell-addr">{{ internetName(h) }}</span>
                </span>
              </td>
              <td data-label="Durum" data-hucre="durum">
                <span class="cell-stack">
                  <StatusPill :tone="stateOf(h).tone" :dot="stateOf(h).tone === 'ok'">{{ stateOf(h).text }}</StatusPill>
                  <span v-if="stateOf(h).note" class="cell-note">{{ stateOf(h).note }}</span>
                </span>
              </td>
              <td class="col-act">
                <button type="button" class="btn btn-secondary btn-sm row-toggle" :disabled="hold" :aria-label="`${h.ad}: ayrıntı`" :aria-expanded="expanded(h)"
                  :aria-controls="expanded(h) ? PANEL_ID : undefined" data-eylem="ayrinti" @click="toggle(h)">
                  Ayrıntı<Icon name="chevron" :size="16" class="row-toggle-icon" />
                </button>
              </td>
            </tr>
            <tr v-if="satir === h.id" class="row-detail" :data-detay="h.id">
              <td :id="PANEL_ID" colspan="6"><AccessRowPanel v-bind="panelProps" v-on="panelOn" /></td>
            </tr>
            </template>
          </tbody>
        </table>
      </div>
      <EmptyState v-else-if="e" title="Adres yok" icon="globe" />
      <p v-else class="meter-note">Okunuyor…</p>
      <p class="meter-note" data-testid="dns-hint">
        İnternet adı için alan adı sağlayıcınızda bir A kaydı gerekir: ad → <span class="mono">{{ wanV4 || "sunucunun internet IPv4 adresi" }}</span>, proxy kapalı (DNS only), AAAA kaydı yok.
      </p>
    </section>

    <!-- raw ports -->
    <section class="card table-card" aria-labelledby="ham-baslik" data-testid="raw-rows">
      <div class="card-head">
        <h2 id="ham-baslik" class="card-title">Doğrudan portlar</h2>
        <span class="meter-note">Caddy dışı · kapalı gelir</span>
      </div>
      <div v-if="rawRows.length" class="table-wrap">
        <table class="data-table raw-table">
          <thead>
            <tr>
              <th scope="col">Hizmet</th>
              <th scope="col">Port</th>
              <th scope="col">Kapsam</th>
              <th scope="col">Adres</th>
              <th scope="col"><span class="sr-only">Eylemler</span></th>
            </tr>
          </thead>
          <tbody>
            <template v-for="h in rawRows" :key="h.id">
            <tr :data-satir="h.id" :class="{ 'row-current': satir === h.id }">
              <th scope="row" class="col-main">
                <strong>{{ rowOwner(h) }}</strong>
                <span class="cell-sub">{{ h.servis }}</span>
              </th>
              <td data-label="Port" class="mono">{{ rawPort(h) }}</td>
              <td data-label="Kapsam" data-hucre="kapsam">
                <span class="segmented scope-choice" role="radiogroup" :aria-label="`${h.ad} · kapsam`">
                  <button
                    v-for="s in SCOPE_CHOICES"
                    :key="s.id"
                    type="button"
                    role="radio"
                    class="segment"
                    :class="{ 'segment-danger': s.id === 'internet' }"
                    :aria-checked="h.satir?.tur === 'ham' && h.satir.kapsam === s.id"
                    :disabled="hold"
                    :data-kapsam="s.id"
                    @click="h.satir?.tur === 'ham' && h.satir.kapsam !== s.id && open(h, { kind: 'kapsam', kapsam: s.id })"
                  >
                    {{ s.text }}
                  </button>
                </span>
              </td>
              <td data-label="Adres"><span class="mono">{{ rawAddress(h) || "—" }}</span></td>
              <td class="col-act">
                <span class="row-actions">
                  <button type="button" class="btn btn-secondary btn-sm row-toggle" :disabled="hold" :aria-label="`${h.ad}: ayrıntı`" :aria-expanded="expanded(h)"
                    :aria-controls="expanded(h) ? PANEL_ID : undefined" data-eylem="ayrinti" @click="toggle(h)">
                    Ayrıntı<Icon name="chevron" :size="16" class="row-toggle-icon" />
                  </button>
                  <button v-if="keyOf(h)?.protokol === 'tcp'" type="button" class="btn btn-secondary btn-sm" :disabled="hold" :aria-label="`${h.ad}: adres aç`"
                    :aria-expanded="expanded(h, 'adres-ac')" :aria-controls="expanded(h, 'adres-ac') ? PANEL_ID : undefined" data-eylem="adres-ac"
                    @click="toggle(h, 'adres-ac')">
                    Adres aç
                  </button>
                </span>
              </td>
            </tr>
            <tr v-if="satir === h.id" class="row-detail" :data-detay="h.id">
              <td :id="PANEL_ID" colspan="5"><AccessRowPanel v-bind="panelProps" v-on="panelOn" /></td>
            </tr>
            </template>
          </tbody>
        </table>
      </div>
      <EmptyState v-else-if="e" title="Doğrudan port yok" text="Uygulamaların bütün portlarının bir adresi var." icon="lock" />
    </section>

  </div>
</template>
