<!-- A container's network and ports (DD-215, DD-217; the Podman page's "Ağ ve portlar"): on a bridge, each
     published port with its scope (an internet port marked, with what that means), the server and the
     container port and the protocol; on the host network there is no mapping, so the sockets its processes
     listen on now, each with the kind of address. A table on wide screens, cards on narrow ones. -->
<script setup lang="ts">
import { computed } from "vue";
import Card from "../../components/ui/Card.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { PUBLIC_RISK, SCOPE_TEXT, networkLabel } from "./container";
import type { ContainerDetail } from "../../api/podman";

const props = defineProps<{ box: ContainerDetail }>();

const LISTEN: Record<string, string> = { all: "Tüm adresler", wan: "WAN", tailscale: "Tailscale", other: "Belirli adres", local: "Yalnız bu sunucu" };
const host = computed(() => props.box.network === "host");
const running = computed(() => props.box.state === "running");

interface PortRow {
  scope: string;
  ip: string;
  host: number;
  inner: number;
  protocol: string;
}

// A Konsol definition says what it publishes (also while stopped); otherwise what podman shows.
const ports = computed<PortRow[]>(() => {
  const cfg = props.box.generic;
  if (cfg) return cfg.ports.map((p) => ({ scope: p.scope, ip: "", host: p.host_port, inner: p.container_port, protocol: p.protocol }));
  return props.box.ports.map((p) => ({ scope: p.scope ?? "other", ip: p.host_ip ?? "", host: p.host_port ?? 0, inner: p.container_port ?? 0, protocol: p.protocol ?? "tcp" }));
});
const anyPublic = computed(() => ports.value.some((p) => p.scope === "public"));
const network = computed(() => (props.box.generic ? networkLabel(props.box.generic.network) : props.box.network || "—"));
const address = (a: string, port: number) => `${a.includes(":") ? `[${a}]` : a}:${port}`;
</script>

<template>
  <Card title="Ağ ve portlar" data-testid="ports">
    <dl class="facts">
      <dt>Ağ</dt>
      <dd :class="{ mono: !box.generic }" data-testid="network">{{ host ? "Sunucu ağı (host)" : network }}</dd>
    </dl>

    <template v-if="host">
      <p v-if="!running" class="meter-note" data-testid="listen-empty">Konteyner çalışmıyor; açık port yok.</p>
      <p v-else-if="!box.listening" class="meter-note" data-testid="listen-empty">Dinlenen portlar okunamadı.</p>
      <p v-else-if="!box.listening.length" class="meter-note" data-testid="listen-empty">Konteyner şu an hiçbir portu dinlemiyor.</p>
      <div v-else class="table-wrap">
        <table class="data-table" aria-label="Dinlenen portlar" data-testid="listening">
          <thead>
            <tr>
              <th scope="col">Adres türü</th>
              <th scope="col">Adres</th>
              <th scope="col">Port</th>
              <th scope="col">Protokol</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(s, i) in box.listening" :key="i">
              <th scope="row" class="col-main">{{ LISTEN[s.scope] ?? s.scope }}</th>
              <td class="mono" data-label="Adres">{{ s.address }}</td>
              <td class="mono" data-label="Port">{{ s.port }}</td>
              <td data-label="Protokol">{{ s.protocol.toUpperCase() }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="meter-note">Sunucu ağında port eşlemesi yoktur; dışarıdan erişimi sunucunun güvenlik duvarı belirler.</p>
    </template>

    <template v-else>
      <div v-if="ports.length" class="table-wrap">
        <table class="data-table" aria-label="Portlar" data-testid="port-table">
          <thead>
            <tr>
              <th scope="col">Erişim</th>
              <th scope="col">Sunucu portu</th>
              <th scope="col">Konteyner portu</th>
              <th scope="col">Protokol</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(p, i) in ports" :key="i" :data-kapsam="p.scope">
              <th scope="row" class="col-main">
                <StatusPill v-if="p.scope === 'public'" tone="danger">{{ SCOPE_TEXT.public }}</StatusPill>
                <template v-else>{{ SCOPE_TEXT[p.scope] ?? p.scope }}</template>
              </th>
              <td class="mono" data-label="Sunucu portu">{{ p.ip ? address(p.ip, p.host) : p.host }}</td>
              <td class="mono" data-label="Konteyner portu">{{ p.inner }}</td>
              <td data-label="Protokol">{{ p.protocol.toUpperCase() }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-else class="meter-note">Port yayımlanmıyor; konteynere yalnız aynı ağdaki konteynerler ulaşır.</p>
      <p v-if="anyPublic" class="warn-text" data-testid="public-warning">{{ PUBLIC_RISK }}</p>
    </template>
  </Card>
</template>
