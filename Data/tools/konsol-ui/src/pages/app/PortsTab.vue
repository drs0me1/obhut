<!-- An application's Portlar (DD-271; access rows since rebuild phase 4): every container port of every service
     with its protocol and its access row. An address: its Tailscale name, its Tailscale port and its internet
     name, the container published only on this server's loopback (127.0.0.1) at its pool port. A raw port: its
     scope (closed, Tailscale or internet) and its host port. Read-only: each row links to its sheet in
     Erişim → Adresler, the row's one home. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { SCOPE_TEXT } from "../../access";
import { live } from "../../live";
import { accessRoute } from "../../sections";
import { UNKNOWN } from "../../format";
import type { UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const domain = computed(() => live.erisim?.alan || live.kaynaklar?.domain || "");
const rows = computed(() =>
  props.detail.servisler.flatMap((s) =>
    s.portlar.map((p) => {
      const a = p.erisim;
      return {
        key: p.id,
        id: p.id,
        service: s.ad,
        port: `${p.port}/${p.protokol}`,
        address: a.tur === "adres",
        name: a.tur === "adres" ? `${a.ad}.${domain.value}` : "",
        tsPort: a.tur === "adres" ? (a.tailscale_portu === null ? "Kapalı" : `TCP ${a.tailscale_portu}`) : "",
        internet: a.tur === "adres" ? a.internet || "Kapalı" : "",
        local: p.yerel_port ? `127.0.0.1:${p.yerel_port}` : UNKNOWN,
        scope: a.tur === "ham" ? SCOPE_TEXT[a.kapsam] : "",
        open: a.tur === "ham" && a.kapsam !== "kapali",
        hostPort: a.tur === "ham" ? `${p.protokol.toUpperCase()} ${a.port}` : "",
      };
    }),
  ),
);
</script>

<template>
  <section class="card" aria-label="Portlar" data-testid="ports">
    <div v-if="rows.length" class="table-wrap">
      <table class="data-table" data-testid="port-table">
        <thead>
          <tr><th scope="col">Port</th><th scope="col">Servis</th><th scope="col">Erişim</th><th scope="col"><span class="sr-only">Erişim satırı</span></th></tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.key" :data-port="r.id">
            <th scope="row" class="col-main mono">{{ r.port }}</th>
            <td data-label="Servis" class="mono">{{ r.service }}</td>
            <td data-label="Erişim" class="port-access">
              <dl v-if="r.address" class="facts port-facts" data-testid="port-address">
                <dt>Adres</dt>
                <dd>Yalnız bu sunucu · <span class="mono">{{ r.local }}</span></dd>
                <dt>Tailscale adı</dt>
                <dd class="mono">{{ r.name }}</dd>
                <dt>Tailscale portu</dt>
                <dd>{{ r.tsPort }}</dd>
                <dt>İnternet adı</dt>
                <dd :class="{ mono: r.internet !== 'Kapalı' }">{{ r.internet }}</dd>
              </dl>
              <span v-else class="cell-stack" data-testid="port-raw">
                <span>Ham port</span>
                <StatusPill :tone="r.open ? 'accent' : 'neutral'">{{ r.scope }}</StatusPill>
                <span class="mono cell-note">{{ r.hostPort }}</span>
              </span>
            </td>
            <td class="col-act">
              <RouterLink :to="accessRoute('adresler', r.id)" class="section-link" data-testid="port-row-link">Adresler'de değiştir</RouterLink>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <EmptyState v-else title="Bu uygulamanın portu yok" icon="globe" />
  </section>
</template>
