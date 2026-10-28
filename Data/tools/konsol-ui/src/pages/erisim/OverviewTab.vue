<!-- Erişim → Genel (rebuild phase 5): four summaries in one template (SummaryCard: the state, at most three
     one-line rows, the tab where the details are): Tailscale (its addresses, the key's end; its link the Tailscale
     admin console, where devices, ACLs and the key change, DD-288), the internet (its
     addresses only; how many ports are open is its state, what they are is Güvenlik duvarı's), WireGuard (its
     networks; its link the WireGuard section, DD-291), the certificates (each name with its end). Then every service with its four cells: the addresses and
     ports it is reached on there, or that it is closed; a warning (a raw port open on the internet, unencrypted
     WebDAV) or a fault is the cell's colour, never a sentence in the table: the words are Genel Bakış' Dikkat. An
     application is one row whatever its ports: its ports under its name, each cell every port's addresses (a
     fault's, else an open port's colour). A service's name leads to its row in Adresler; an application with more
     than one port to its own Erişim, where each port has its link. A table on wide screens, cards on narrow ones. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink, type RouteLocationRaw } from "vue-router";
import SummaryCard, { type SummaryRow } from "../../components/ui/SummaryCard.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import type { Tone } from "../../components/ui/types";
import { Icon } from "../../components/icons";
import { CELL_TEXT, addressPieces, cellTone } from "../../apps";
import { isAccessRow, portKey } from "../../access";
import { accessRoute } from "../../sections";
import { tailscaleAdmin } from "../../links";
import { appRoute } from "../../router";
import { live, serverNow } from "../../live";
import { UNKNOWN, date, dayMonth, daysUntil } from "../../format";
import type { ErisimDurumu, ErisimHucresi, Hizmet } from "../../api/sema";

const e = computed(() => live.erisim);

type ColumnKey = "yerel" | "tailscale" | "wireguard" | "internet";
const COLUMNS: readonly { key: ColumnKey; title: string }[] = [
  { key: "yerel", title: "Bu sunucu" },
  { key: "tailscale", title: "Tailscale" },
  { key: "wireguard", title: "WireGuard" },
  { key: "internet", title: "İnternet" },
];

/** A row of the table: a service, or an application with every one of its ports. */
interface Shown {
  id: string;
  ad: string;
  sub: string;
  to: RouteLocationRaw | null;
  cells: Record<ColumnKey, ErisimHucresi>;
  app: string;
  rows: Hizmet[];
}

/** An application's cells of one column as one: every port's addresses, the state that matters most (a fault, else
 *  open, else partly, else closed), a warning from any of them. */
function merged(cells: ErisimHucresi[]): ErisimHucresi {
  const shown = cells.filter((c) => c.durum !== "yok");
  const first = cells[0] ?? { durum: "yok", adresler: [], not: "", uyari: "" };
  if (!shown.length) return first;
  const order: readonly ErisimDurumu[] = ["hata", "acik", "kismen", "kapali"];
  const durum = order.find((d) => shown.some((c) => c.durum === d)) ?? "kapali";
  return { durum, adresler: [...new Set(shown.flatMap((c) => c.adresler))], not: "", uyari: shown.map((c) => c.uyari).find(Boolean) ?? "" };
}

/** The ports of an application's rows under its name: "8080/tcp · 8092/tcp", each with its service when the rows
 *  belong to more than one. */
function portsLine(rows: Hizmet[]): string {
  const keys = rows.map((h) => portKey(h.anahtar ?? ""));
  const services = new Set(keys.map((k) => k?.servis));
  return keys.map((k, i) => (k ? `${services.size > 1 ? k.servis + " " : ""}${k.port}/${k.protokol}` : rows[i]?.aciklama ?? "")).join(" · ");
}

const shown = computed<Shown[]>(() => {
  const out: Shown[] = [];
  const byApp = new Map<string, Shown>();
  for (const h of e.value?.hizmetler ?? []) {
    const app = h.tur === "uygulama" && h.uygulama ? h.uygulama : "";
    const cells = { yerel: h.yerel, tailscale: h.tailscale, wireguard: h.wireguard, internet: h.internet };
    const group = app ? byApp.get(app) : undefined;
    if (group) {
      group.rows.push(h);
      continue;
    }
    const row: Shown = { id: h.id, ad: app || h.ad, sub: h.aciklama || KIND[h.tur], to: isAccessRow(h) ? accessRoute("adresler", h.id) : null, cells, app, rows: [h] };
    if (app) byApp.set(app, row);
    out.push(row);
  }
  for (const g of byApp.values()) {
    g.sub = portsLine(g.rows);
    if (g.rows.length > 1) {
      g.to = { ...appRoute(g.app), query: { sekme: "erisim" } };
      for (const k of COLUMNS) g.cells[k.key] = merged(g.rows.map((h) => h[k.key]));
    }
  }
  return out;
});

/** Whether a cell shows addresses: the addresses and ports it is reached on (or that a blocking rule closes). */
const addressed = (c: ErisimHucresi): boolean => c.durum !== "yok" && c.adresler.length > 0;
/** What a cell shows: its addresses and ports when it has them, else its state's word ("—" when it does not apply). */
const cellLines = (c: ErisimHucresi): string[] => (addressed(c) ? c.adresler : [CELL_TEXT[c.durum] ?? UNKNOWN]);
const pieces = addressPieces;
const KIND: Record<Hizmet["tur"], string> = {
  konsol: "Konsol", uygulama: "Uygulama portu", konteyner: "Konteyner", paylasim: "Paylaşım", sistem: "Sistem", vpn: "VPN ağı", kural: "Kural",
};

const ts = computed(() => e.value?.ozet.tailscale ?? null);
const TS_STATE: Record<string, { text: string; tone: Tone }> = {
  bagli: { text: "Bağlı", tone: "ok" },
  "bagli-degil": { text: "Bağlı değil", tone: "danger" },
  bilinmiyor: { text: "Bilinmiyor", tone: "neutral" },
};
const tsState = computed(() => {
  const s = TS_STATE[ts.value?.durum ?? "bilinmiyor"] ?? (TS_STATE.bilinmiyor as { text: string; tone: Tone });
  return { ...s, dot: ts.value?.durum === "bagli" };
});
const keyLeft = computed(() => (ts.value?.anahtar_bitis ? daysUntil(ts.value.anahtar_bitis, serverNow()) : null));
const tsAdmin = tailscaleAdmin("machines");
/** An address row: the address, or "yok" for a family the server has none of. */
const addressRow = (label: string, value: string | undefined | null): SummaryRow =>
  value ? { label, value, mono: true } : { label, value: "yok", tone: "muted" };
const tsRows = computed<SummaryRow[]>(() => {
  const t = ts.value;
  if (!t) return [];
  const third: SummaryRow = t.anahtar_bitis
    ? { label: "Anahtar", value: date(t.anahtar_bitis), hint: `Tailscale anahtarı ${date(t.anahtar_bitis)} tarihine kadar geçerli`,
        tone: keyLeft.value !== null && keyLeft.value < 14 ? "warn" : undefined }
    : { label: "Cihaz", value: t.ad || UNKNOWN, mono: Boolean(t.ad) };
  return [addressRow("IPv4", t.ipv4), addressRow("IPv6", t.ipv6), third];
});

const net = computed(() => e.value?.ozet.internet ?? null);
const netRows = computed<SummaryRow[]>(() => (net.value ? [addressRow("IPv4", net.value.ipv4), addressRow("IPv6", net.value.ipv6)] : []));
/** How many ports are open on the internet addresses; which ones is Güvenlik duvarı's. */
const netState = computed<{ text: string; tone: Tone }>(() => {
  const n = net.value?.acik.length ?? 0;
  return n ? { text: `${n} port açık`, tone: "neutral" } : { text: "Port açık değil", tone: "neutral" };
});

const wg = computed(() => e.value?.ozet.wireguard ?? null);
const wgState = computed<{ text: string; tone: Tone; dot?: boolean }>(() => {
  const w = wg.value;
  if (!w || !w.aglar.length) return { text: "Kapalı", tone: "neutral" };
  if (w.durduruldu) return { text: "Durduruldu", tone: "neutral" };
  return w.aglar.some((a) => a.etkin) ? { text: "Açık", tone: "ok", dot: true } : { text: "Kapalı", tone: "neutral" };
});
const wgRows = computed<SummaryRow[]>(() =>
  (wg.value?.aglar ?? []).map((a) => {
    const on = a.etkin && !wg.value?.durduruldu;
    return { label: a.arayuz, value: `${a.ad ? a.ad + " · " : ""}UDP ${a.port}${on ? "" : " · kapalı"}`, tone: on ? undefined : "muted" };
  }),
);

const certs = computed(() =>
  (e.value?.ozet.sertifikalar ?? []).map((c) => {
    const left = c.bitis ? daysUntil(c.bitis, serverNow()) : null;
    const ok = c.durum === "gecerli";
    return { ad: c.ad, ok, bitis: c.bitis, soon: ok && left !== null && left < 14 };
  }),
);
/** Each internet name with the day its certificate ends (a problem: "Hazır değil", its details in Adresler). */
const certRows = computed<SummaryRow[]>(() =>
  certs.value.map((c) => ({
    label: c.ok ? (c.bitis ? dayMonth(c.bitis) : "Geçerli") : "Hazır değil",
    value: c.ad,
    mono: true,
    tone: !c.ok || c.soon ? "warn" : undefined,
    hint: c.ok ? `${c.ad}: ${c.bitis ? date(c.bitis) + " tarihine kadar" : "geçerli"}` : `${c.ad}: hazır değil; DNS kaydını ve 443 portunu denetleyin.`,
  })),
);
const certState = computed<{ text: string; tone: Tone; dot?: boolean }>(() => {
  if (!certs.value.length) return { text: "Yok", tone: "neutral" };
  if (certs.value.some((c) => !c.ok)) return { text: "Sorunlu", tone: "warning" };
  if (certs.value.some((c) => c.soon)) return { text: "Yakında doluyor", tone: "warning" };
  return { text: "Geçerli", tone: "ok", dot: true };
});
</script>

<template>
  <div class="access-tab" data-testid="access-overview">
    <section v-if="e?.hatalar.length" class="notice notice-warning" aria-labelledby="erisim-hata-baslik" data-testid="access-errors">
      <Icon name="alert" class="notice-icon" />
      <div>
        <h2 id="erisim-hata-baslik" class="notice-title">Bazı bilgiler okunamadı</h2>
        <ul class="notice-list">
          <li v-for="(x, i) in e.hatalar" :key="i">{{ x }}</li>
        </ul>
      </div>
    </section>

    <template v-if="e">
      <div class="summary-grid">
        <SummaryCard title="Tailscale" :state="tsState" :rows="tsRows" empty="Tailscale okunamadı." :link="{ to: tsAdmin, text: 'Yönetim paneli', external: true }"
          data-testid="sum-tailscale" />
        <SummaryCard title="İnternet" :state="netState" :rows="netRows" empty="İnternet adresi okunamadı."
          :link="{ to: accessRoute('guvenlik-duvari'), text: 'Güvenlik duvarı' }" data-testid="sum-internet" />
        <SummaryCard title="WireGuard" :state="wgState" :rows="wgRows" empty="Ağ yok; açınca ilk ağ kurulur." :link="{ to: '/wireguard', text: 'WireGuard' }"
          data-testid="sum-wireguard" />
        <SummaryCard title="Sertifikalar" :state="certState" :rows="certRows" empty="İnternet adı yok." :link="{ to: accessRoute('adresler'), text: 'Adresler' }"
          data-testid="sum-certs" />
      </div>

      <section class="card matrix-card" aria-labelledby="matris-baslik" data-testid="matrix">
        <h2 id="matris-baslik" class="card-title">Hizmetler ve erişim</h2>
        <div class="table-wrap">
          <table class="data-table matrix">
            <thead>
              <tr>
                <th scope="col">Hizmet</th>
                <th v-for="c in COLUMNS" :key="c.key" scope="col">{{ c.title }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="s in shown" :key="s.id" :data-hizmet="s.id" :data-uygulama="s.app || undefined">
                <th scope="row" class="col-main">
                  <RouterLink v-if="s.to" :to="s.to" class="matrix-name" data-testid="row-link">{{ s.ad }}</RouterLink>
                  <strong v-else class="matrix-name">{{ s.ad }}</strong>
                  <span class="cell-sub">{{ s.sub }}</span>
                </th>
                <td v-for="c in COLUMNS" :key="c.key" :data-label="c.title" :data-hucre="c.key" :data-durum="s.cells[c.key].durum" class="matrix-cell">
                  <span class="reach" :class="['reach-' + cellTone(s.cells[c.key]), { 'reach-none': s.cells[c.key].durum === 'yok' }]">
                    <span class="reach-dot" aria-hidden="true"></span>
                    <span class="reach-lines">
                      <span v-if="addressed(s.cells[c.key])" class="sr-only">{{ CELL_TEXT[s.cells[c.key].durum] }}{{ s.cells[c.key].uyari ? ", uyarı" : "" }}: </span>
                      <span v-for="(line, i) in cellLines(s.cells[c.key])" :key="i" :class="{ mono: addressed(s.cells[c.key]) }"
                        ><template v-for="(part, j) in pieces(line)" :key="j"><wbr v-if="j" />{{ part }}</template></span
                      >
                    </span>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </template>
    <section v-else class="card" aria-label="Erişim">
      <EmptyState title="Erişim henüz okunamadı" text="Sunucu yanıt verince burada görünür." icon="globe" />
    </section>
  </div>
</template>
