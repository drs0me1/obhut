<!-- Erişim → Genel (rebuild phase 5): the summaries (Tailscale, the internet with what is open on it, WireGuard,
     the certificates), then every service with its four cells in plain words. "Teknik ayrıntı" (?teknik=1) adds
     the addresses and the technical lines. A table on wide screens, cards on narrow ones. An access row (Konsol,
     Paylaşımlar, each application port) links to its sheet in Adresler, where it changes; Paylaşımlar' row also
     leads to Dosyalar → Paylaşımlar for each folder's connections. Warnings are Genel Bakış' Dikkat; here a
     cell says what is wrong. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import type { Tone } from "../../components/ui/types";
import { Icon } from "../../components/icons";
import { CELL_TEXT, CELL_TONE } from "../../apps";
import { isAccessRow } from "../../access";
import { accessRoute, filesRoute } from "../../sections";
import { live, serverNow } from "../../live";
import { useQueryFlag } from "../../query";
import { UNKNOWN, date, daysUntil } from "../../format";
import type { ErisimHucresi, Hizmet } from "../../api/sema";

const technical = useQueryFlag("teknik");
const e = computed(() => live.erisim);

const COLUMNS: readonly { key: "yerel" | "tailscale" | "wireguard" | "internet"; title: string }[] = [
  { key: "yerel", title: "Bu sunucu" },
  { key: "tailscale", title: "Tailscale" },
  { key: "wireguard", title: "WireGuard" },
  { key: "internet", title: "İnternet" },
];

// WireGuard's note is the same for every service (VPN networks lead only to the internet): said once.
const vpnNote = computed(() => e.value?.ozet.wireguard.not ?? "");
const noteOf = (key: string, c: ErisimHucresi) => (key === "wireguard" && c.not === vpnNote.value ? "" : c.not);
const cellTone = (c: ErisimHucresi): Tone => (c.uyari ? "warning" : CELL_TONE[c.durum] ?? "neutral");
const cellText = (c: ErisimHucresi) => CELL_TEXT[c.durum] ?? UNKNOWN;
const KIND: Record<Hizmet["tur"], string> = {
  konsol: "Konsol", uygulama: "Uygulama portu", konteyner: "Konteyner", paylasim: "Paylaşım", sistem: "Sistem", vpn: "VPN ağı", kural: "Kural",
};

const ts = computed(() => e.value?.ozet.tailscale ?? null);
const TS_STATE: Record<string, { text: string; tone: Tone }> = {
  bagli: { text: "Bağlı", tone: "ok" },
  "bagli-degil": { text: "Bağlı değil", tone: "danger" },
  bilinmiyor: { text: "Bilinmiyor", tone: "neutral" },
};
const tsState = computed(() => TS_STATE[ts.value?.durum ?? "bilinmiyor"] ?? (TS_STATE.bilinmiyor as { text: string; tone: Tone }));
const keyLeft = computed(() => (ts.value?.anahtar_bitis ? daysUntil(ts.value.anahtar_bitis, serverNow()) : null));

const net = computed(() => e.value?.ozet.internet ?? null);
/** What is open on the internet address, in one line ("SSH 22/tcp, Oyun 27015/udp (yalnız IPv4, kural)"). */
const openLine = computed(() =>
  (net.value?.acik ?? [])
    .map((p) => {
      const extra = [p.aileler.length === 1 ? `yalnız IPv${p.aileler[0]}` : "", p.kaynak === "kural" ? "kural" : ""].filter(Boolean).join(", ");
      return `${p.ad} ${p.port}/${p.proto}${extra ? ` (${extra})` : ""}`;
    })
    .join(", "),
);

const wg = computed(() => e.value?.ozet.wireguard ?? null);
const wgState = computed<{ text: string; tone: Tone }>(() => {
  const w = wg.value;
  if (!w || !w.aglar.length) return { text: "Kapalı", tone: "neutral" };
  if (w.durduruldu) return { text: "Durduruldu", tone: "neutral" };
  return w.aglar.some((a) => a.etkin) ? { text: "Açık", tone: "ok" } : { text: "Kapalı", tone: "neutral" };
});

const certs = computed(() =>
  (e.value?.ozet.sertifikalar ?? []).map((c) => {
    const left = c.bitis ? daysUntil(c.bitis, serverNow()) : null;
    const ok = c.durum === "gecerli";
    return {
      ad: c.ad,
      ok,
      text: !ok ? "Hazır değil; DNS kaydını ve 443 portunu denetleyin." : c.bitis ? `${date(c.bitis)} tarihine kadar` : "Geçerli",
      soon: ok && left !== null && left < 14,
    };
  }),
);
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
        <Card title="Tailscale" :level="3" data-testid="sum-tailscale">
          <template #actions><StatusPill :tone="tsState.tone" :dot="ts?.durum === 'bagli'">{{ tsState.text }}</StatusPill></template>
          <dl class="facts">
            <dt>Cihaz</dt>
            <dd class="mono">{{ ts?.ad || UNKNOWN }}</dd>
            <dt>Adres</dt>
            <dd class="mono">{{ [ts?.ipv4, ts?.ipv6].filter(Boolean).join(" · ") || UNKNOWN }}</dd>
            <template v-if="ts?.anahtar_bitis">
              <dt>Anahtar</dt>
              <dd :class="{ 'warn-text': keyLeft !== null && keyLeft < 14 }">{{ date(ts.anahtar_bitis) }} tarihine kadar</dd>
            </template>
          </dl>
        </Card>
        <Card title="İnternet" :level="3" data-testid="sum-internet">
          <dl class="facts">
            <dt>Adres</dt>
            <dd class="mono">{{ [net?.ipv4, net?.ipv6].filter(Boolean).join(" · ") || UNKNOWN }}</dd>
            <dt>Açık</dt>
            <dd data-testid="sum-internet-open">{{ openLine || "Hiçbir port açık değil" }}</dd>
          </dl>
        </Card>
        <Card title="WireGuard" :level="3" data-testid="sum-wireguard">
          <template #actions><StatusPill :tone="wgState.tone" :dot="wgState.tone === 'ok'">{{ wgState.text }}</StatusPill></template>
          <ul v-if="wg?.aglar.length" class="fact-list" aria-label="WireGuard ağları">
            <li v-for="a in wg.aglar" :key="a.arayuz">
              <strong>{{ a.arayuz }}</strong><template v-if="a.ad"> · {{ a.ad }}</template> · UDP {{ a.port }} ·
              <span :class="a.etkin && !wg.durduruldu ? 'ok-text' : 'muted'">{{ a.etkin && !wg.durduruldu ? "açık" : "kapalı" }}</span>
            </li>
          </ul>
          <p v-else class="meter-note" data-testid="sum-wireguard-none">Ağ yok; açınca ilk ağ kurulur.</p>
          <RouterLink :to="accessRoute('wireguard')" class="btn btn-secondary btn-sm fit" data-testid="sum-wireguard-link">WireGuard</RouterLink>
        </Card>
        <Card title="Sertifikalar" :level="3" data-testid="sum-certs">
          <ul v-if="certs.length" class="cert-list" aria-label="Sertifikalar">
            <li v-for="c in certs" :key="c.ad" class="cert">
              <span class="cert-text">
                <strong class="mono">{{ c.ad }}</strong>
                <span :class="{ 'warn-text': c.soon }">{{ c.text }}</span>
              </span>
              <StatusPill :tone="c.ok ? 'ok' : 'warning'">{{ c.ok ? "Geçerli" : "Sorunlu" }}</StatusPill>
            </li>
          </ul>
          <p v-else class="meter-note">İnternet adı yok.</p>
        </Card>
      </div>

      <section class="card matrix-card" aria-labelledby="matris-baslik" data-testid="matrix">
        <div class="card-head">
          <h2 id="matris-baslik" class="card-title">Hizmetler ve erişim</h2>
          <Switch v-model="technical" label="Teknik ayrıntı" />
        </div>
        <div class="table-wrap">
          <table class="data-table matrix">
            <thead>
              <tr>
                <th scope="col">Hizmet</th>
                <th v-for="c in COLUMNS" :key="c.key" scope="col">{{ c.title }}</th>
              </tr>
            </thead>
            <tbody>
              <template v-for="h in e.hizmetler" :key="h.id">
                <tr :data-hizmet="h.id">
                  <th scope="row" class="col-main">
                    <strong>{{ h.ad }}</strong>
                    <span class="cell-sub">{{ h.aciklama || KIND[h.tur] }}</span>
                    <RouterLink v-if="isAccessRow(h)" :to="accessRoute('adresler', h.id)" class="cell-note" data-testid="row-link">Adresler'de değiştir</RouterLink>
                    <RouterLink v-if="h.tur === 'paylasim'" :to="filesRoute('paylasimlar')" class="cell-note" data-testid="share-folders">Klasörler: Dosyalar → Paylaşımlar</RouterLink>
                  </th>
                  <td v-for="c in COLUMNS" :key="c.key" :data-label="c.title" :data-hucre="c.key" class="matrix-cell">
                    <span class="matrix-value">
                      <StatusPill :tone="cellTone(h[c.key])">{{ cellText(h[c.key]) }}</StatusPill>
                      <span v-if="h[c.key].uyari" class="warn-text">{{ h[c.key].uyari }}</span>
                      <span v-if="noteOf(c.key, h[c.key])" class="cell-note">{{ noteOf(c.key, h[c.key]) }}</span>
                      <span v-if="technical && h[c.key].adresler.length" class="mono cell-addr">{{ h[c.key].adresler.join(" · ") }}</span>
                    </span>
                  </td>
                </tr>
                <tr v-if="technical && h.ayrinti.length" class="matrix-detail" :data-ayrinti="h.id">
                  <td colspan="5">
                    <dl class="facts mono">
                      <template v-for="(line, i) in h.ayrinti" :key="i">
                        <dt>{{ line.baslik }}</dt>
                        <dd>{{ line.deger }}</dd>
                      </template>
                    </dl>
                  </td>
                </tr>
              </template>
            </tbody>
          </table>
        </div>
        <p v-if="vpnNote" class="meter-note" data-testid="vpn-note">WireGuard: {{ vpnNote }}</p>
      </section>
    </template>
    <section v-else class="card" aria-label="Erişim">
      <EmptyState title="Erişim henüz okunamadı" text="Sunucu yanıt verince burada görünür." icon="globe" />
    </section>
  </div>
</template>
