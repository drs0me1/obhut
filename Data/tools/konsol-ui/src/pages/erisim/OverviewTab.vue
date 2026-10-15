<!-- Erişim → Genel: warnings first, each with its fix (a publication in the Yayınla flow, an application's
     page, the Tailscale tab); the summaries (Tailscale, the internet with its open ports, WireGuard,
     certificates); then every service with its four cells in plain words. "Teknik ayrıntı" (?teknik=1) adds
     the addresses and the technical lines. A table on wide screens, cards on narrow ones. WebDAV's row leads
     to Dosyalar → Paylaşımlar for each folder's connections. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon, type IconName } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import type { Tone } from "../../components/ui/types";
import { CELL_TEXT, CELL_TONE } from "../../apps";
import { fixRoute } from "../../access";
import { accessRoute, filesRoute } from "../../sections";
import { live, serverNow } from "../../live";
import { useQueryFlag } from "../../query";
import { UNKNOWN, date, daysUntil } from "../../format";
import type { ErisimHucresi, Hizmet } from "../../api/sema";

const technical = useQueryFlag("teknik");
const e = computed(() => live.erisim);

const COLUMNS: readonly { key: "yerel" | "tailscale" | "wireguard" | "internet"; title: string; icon: IconName }[] = [
  { key: "yerel", title: "Bu sunucu", icon: "server" },
  { key: "tailscale", title: "Tailscale", icon: "tailnet" },
  { key: "wireguard", title: "WireGuard", icon: "shield" },
  { key: "internet", title: "İnternet", icon: "globe" },
];

// WireGuard's note is the same for every service (VPN networks lead only to the internet): said once.
const vpnNote = computed(() => e.value?.ozet.wireguard.not ?? "");
const noteOf = (key: string, c: ErisimHucresi) => (key === "wireguard" && c.not === vpnNote.value ? "" : c.not);
const cellTone = (c: ErisimHucresi): Tone => (c.uyari ? "warning" : CELL_TONE[c.durum] ?? "neutral");
const cellText = (c: ErisimHucresi) => CELL_TEXT[c.durum] ?? UNKNOWN;
const KIND: Record<Hizmet["tur"], string> = {
  konsol: "Konsol", paket: "Uygulama", konteyner: "Konteyner", elle: "Elle adres", paylasim: "Paylaşım", sistem: "Sistem", vpn: "VPN ağı", kural: "Kural",
};

const warnings = computed(() =>
  (e.value?.uyarilar ?? []).map((u, i) => ({ key: i, u, to: fixRoute(u.duzelt), tone: (u.seviye === "bad" ? "danger" : "warning") as Tone })),
);

const ts = computed(() => e.value?.ozet.tailscale ?? null);
const TS_STATE: Record<string, { text: string; tone: Tone }> = {
  bagli: { text: "Bağlı", tone: "ok" },
  "bagli-degil": { text: "Bağlı değil", tone: "danger" },
  bilinmiyor: { text: "Bilinmiyor", tone: "neutral" },
};
const tsState = computed(() => TS_STATE[ts.value?.durum ?? "bilinmiyor"] ?? (TS_STATE.bilinmiyor as { text: string; tone: Tone }));
const keyLeft = computed(() => (ts.value?.anahtar_bitis ? daysUntil(ts.value.anahtar_bitis, serverNow()) : null));

const net = computed(() => e.value?.ozet.internet ?? null);
const openPorts = computed(() =>
  (net.value?.acik ?? []).map((p) => ({
    key: `${p.ad}:${p.port}:${p.proto}`,
    text: `${p.ad} · ${p.port}/${p.proto}`,
    detail: [p.aileler.length === 1 ? `yalnız IPv${p.aileler[0]}` : "", p.kaynak === "kural" ? "sizin kuralınız" : ""].filter(Boolean).join(" · "),
  })),
);
const wg = computed(() => e.value?.ozet.wireguard ?? null);
const certs = computed(() => e.value?.ozet.sertifikalar ?? []);
const certLeft = (bitis: number | null) => (bitis ? daysUntil(bitis, serverNow()) : null);
</script>

<template>
  <div class="access-tab" data-testid="access-overview">
    <section v-if="warnings.length" class="card access-warnings" aria-labelledby="erisim-uyari-baslik" data-testid="access-warnings">
      <h2 id="erisim-uyari-baslik" class="card-title">Dikkat isteyen konular</h2>
      <ul class="problems">
        <li v-for="w in warnings" :key="w.key" class="problem" :class="'problem-' + w.tone" :data-hizmet="w.u.hizmet">
          <Icon :name="w.tone === 'danger' ? 'xcircle' : 'alert'" :size="22" class="problem-icon" />
          <div class="problem-text"><strong>{{ w.u.metin }}</strong></div>
          <RouterLink :to="w.to" class="btn btn-primary" data-eylem="duzelt">Düzelt</RouterLink>
        </li>
      </ul>
    </section>

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
        <Card title="Tailscale" data-testid="sum-tailscale">
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
          <RouterLink :to="accessRoute('tailscale')" class="section-link">Tailscale ayrıntısı</RouterLink>
        </Card>
        <Card title="İnternet" data-testid="sum-internet">
          <dl class="facts">
            <dt>Adres</dt>
            <dd class="mono">{{ [net?.ipv4, net?.ipv6].filter(Boolean).join(" · ") || UNKNOWN }}</dd>
          </dl>
          <ul v-if="openPorts.length" class="fact-list" aria-label="İnternete açık portlar">
            <li v-for="p in openPorts" :key="p.key"><span class="mono">{{ p.text }}</span><span v-if="p.detail" class="muted"> · {{ p.detail }}</span></li>
          </ul>
          <p v-else class="meter-note">İnternete açık port yok.</p>
          <RouterLink :to="accessRoute('guvenlik-duvari')" class="section-link">Güvenlik duvarı</RouterLink>
        </Card>
        <Card title="WireGuard" data-testid="sum-wireguard">
          <ul v-if="wg?.aglar.length" class="fact-list" aria-label="WireGuard ağları">
            <li v-for="a in wg.aglar" :key="a.arayuz">
              <strong>{{ a.arayuz }}</strong><template v-if="a.ad"> · {{ a.ad }}</template> · UDP {{ a.port }} ·
              <span :class="a.etkin ? 'ok-text' : 'muted'">{{ a.etkin ? "açık" : "kapalı" }}</span>
            </li>
          </ul>
          <p v-else class="meter-note">{{ wg?.kurulu ? "Ağ yok." : "WireGuard ağı yok." }}</p>
          <p v-if="wg?.not" class="meter-note">{{ wg.not }}</p>
          <RouterLink :to="accessRoute('wireguard')" class="section-link">WireGuard ağları</RouterLink>
        </Card>
        <Card title="Sertifikalar" data-testid="sum-certs">
          <ul v-if="certs.length" class="fact-list" aria-label="Sertifikalar">
            <li v-for="c in certs" :key="c.ad">
              <span class="mono">{{ c.ad }}</span> ·
              <span v-if="c.durum !== 'gecerli'" class="warn-text">hazır değil</span>
              <span v-else-if="c.bitis" :class="{ 'warn-text': (certLeft(c.bitis) ?? 99) < 14 }">{{ date(c.bitis) }} tarihine kadar</span>
              <span v-else>geçerli</span>
            </li>
          </ul>
          <p v-else class="meter-note">İnternet adı olan yayın yok.</p>
          <RouterLink :to="accessRoute('adresler')" class="section-link">Adresler</RouterLink>
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
      <EmptyState
        :title="live.erisimYok ? 'Bu sunucu Erişim görünümünü vermiyor' : 'Erişim henüz okunamadı'"
        :text="live.erisimYok ? 'Sunucuyu güncelleyince burada görünür.' : 'Sunucu yanıt verince burada görünür.'"
        icon="globe"
      />
    </section>
  </div>
</template>
