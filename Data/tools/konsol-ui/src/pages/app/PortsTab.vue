<!-- An application's Portlar (DD-271, phase 3): every container port of every service with its protocol and
     its use as answered (an address, i.e. a Caddy row, or a raw port). An address's container is published only
     on this server's loopback (127.0.0.1) at its pool port; a raw port is closed (A2). Read-only. -->
<script setup lang="ts">
import { computed } from "vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { UNKNOWN } from "../../format";
import type { UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const USE_TEXT = { caddy: "Adres (Caddy satırı)", raw: "Ham port" } as const;
const rows = computed(() =>
  props.detail.servisler.flatMap((s) =>
    s.portlar.map((p) => ({
      key: `${s.ad}:${p.port}/${p.protokol}`,
      service: s.ad,
      port: `${p.port}/${p.protokol}`,
      use: USE_TEXT[p.kullanim] ?? p.kullanim,
      caddy: p.kullanim === "caddy",
      reach: p.kullanim === "caddy" ? (p.yerel_port ? `127.0.0.1:${p.yerel_port}` : UNKNOWN) : "",
    })),
  ),
);
</script>

<template>
  <section class="card" aria-label="Portlar" data-testid="ports">
    <div v-if="rows.length" class="table-wrap">
      <table class="data-table" data-testid="port-table">
        <thead>
          <tr><th scope="col">Port</th><th scope="col">Servis</th><th scope="col">Kullanım</th><th scope="col">Erişim</th></tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.key" :data-port="r.key">
            <th scope="row" class="col-main mono">{{ r.port }}</th>
            <td data-label="Servis" class="mono">{{ r.service }}</td>
            <td data-label="Kullanım">{{ r.use }}</td>
            <td data-label="Erişim">
              <span v-if="r.caddy">Yalnız bu sunucu · <span class="mono">{{ r.reach }}</span></span>
              <StatusPill v-else tone="neutral">Kapalı</StatusPill>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <EmptyState v-else title="Bu uygulamanın portu yok" icon="globe" />
  </section>
</template>
