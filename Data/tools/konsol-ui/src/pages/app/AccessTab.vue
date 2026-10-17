<!-- An application's Erişim (rebuild phase 5; DD-275's rows): every container port of every service with its access
     row, read-only. An address: its Tailscale name, its Tailscale port and its internet name, the container published
     only on this server's loopback (Yalnız bu sunucu) at its pool port. A raw port: closed, Tailscale or internet,
     with where it is reached. Each row links to its sheet in Erişim → Adresler, the row's one home. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { SCOPE_TEXT } from "../../access";
import { live } from "../../live";
import { accessRoute } from "../../sections";
import type { UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const domain = computed(() => live.erisim?.alan || live.kaynaklar?.domain || "");
const tailscale = computed(() => live.erisim?.ozet.tailscale.ipv4 || live.kaynaklar?.net?.tailscale || "");
const wan = computed(() => live.erisim?.ozet.internet.ipv4 || live.kaynaklar?.net?.wan || "");
const rows = computed(() =>
  props.detail.servisler.flatMap((s) =>
    s.portlar.map((p) => {
      const a = p.erisim;
      const port = `${s.ad} · ${p.port}/${p.protokol.toUpperCase()}`;
      if (a.tur === "adres") {
        return {
          id: p.id, port, address: true as const,
          local: p.yerel_port ? `127.0.0.1:${p.yerel_port} → ${p.port}` : "",
          name: domain.value ? `${a.ad}.${domain.value}` : a.ad,
          tsPort: a.tailscale_portu === null ? "" : tailscale.value ? `${tailscale.value}:${a.tailscale_portu}` : `TCP ${a.tailscale_portu}`,
          internet: a.internet,
        };
      }
      const host = a.kapsam === "internet" ? wan.value : a.kapsam === "tailscale" ? tailscale.value : "";
      return {
        id: p.id, port, address: false as const,
        scope: a.kapsam === "tailscale" ? "Yalnız Tailscale" : SCOPE_TEXT[a.kapsam],
        open: a.kapsam !== "kapali",
        where: a.kapsam === "kapali" ? "" : host ? `${host}:${a.port}` : `${p.protokol.toUpperCase()} ${a.port}`,
      };
    }),
  ),
);
const first = computed(() => rows.value[0]?.id ?? "");
</script>

<template>
  <section class="card table-card" aria-labelledby="erisim-baslik" data-testid="access">
    <div class="card-head">
      <h2 id="erisim-baslik" class="card-title">Bu uygulamanın adresleri</h2>
      <RouterLink :to="accessRoute('adresler', first)" class="btn btn-secondary btn-sm" data-testid="access-edit">Erişim'de düzenle</RouterLink>
    </div>
    <p class="meter-note">Burada yalnız görünür; adresler, Tailscale portu, internet adı ve ham portlar Erişim → Adresler'de değişir.</p>
    <div v-if="rows.length" class="table-wrap">
      <table class="data-table app-access-table" data-testid="access-table">
        <thead>
          <tr>
            <th scope="col">Port</th>
            <th scope="col">Tür</th>
            <th scope="col">Tailscale adı</th>
            <th scope="col">Tailscale portu</th>
            <th scope="col">İnternet adı</th>
            <th scope="col"><span class="sr-only">Erişim satırı</span></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.id" :data-satir="r.id">
            <th scope="row" class="col-main">
              <strong>{{ r.port }}</strong>
              <span v-if="r.address && r.local" class="cell-sub mono">Yalnız bu sunucu · {{ r.local }}</span>
            </th>
            <td data-label="Tür">
              <StatusPill :tone="r.address ? 'accent' : 'warning'">{{ r.address ? "Adres" : "Ham port" }}</StatusPill>
            </td>
            <template v-if="r.address">
              <td data-label="Tailscale adı" class="mono">{{ r.name }}</td>
              <td data-label="Tailscale portu" :class="{ mono: r.tsPort, muted: !r.tsPort }">{{ r.tsPort || "Kapalı" }}</td>
              <td data-label="İnternet adı" :class="{ mono: r.internet, muted: !r.internet }">{{ r.internet || "Kapalı" }}</td>
            </template>
            <td v-else colspan="3" data-label="Erişim" data-testid="access-raw">
              <span class="cell-stack">
                <StatusPill :tone="r.open ? 'warning' : 'neutral'">{{ r.scope }}</StatusPill>
                <span v-if="r.where" class="mono cell-note">{{ r.where }}</span>
              </span>
            </td>
            <td class="col-act">
              <RouterLink :to="accessRoute('adresler', r.id)" class="section-link" :aria-label="`${r.port}: Adresler'de aç`" data-testid="access-link">Adresler'de aç</RouterLink>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <EmptyState v-else title="Bu uygulamanın portu yok" text="Dosyasında port yok; yalnız kendi ağındaki servisler ona ulaşır." icon="globe" />
  </section>
</template>
