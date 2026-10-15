<!-- Gelişmiş (DD-258, phase 4a; DD-266): the technical views, read-only except Podman's resources. Tabs in the
     address (?sekme=): Caddy (the effective sites and the raw files), DNS (dnsmasq's names and files), Güvenlik
     duvarı (a way to Erişim's technical rules, which are not repeated here) and Podman (images, volumes,
     networks). Caddy and DNS share one read of GET /api/konsol/gelismis; "Yenile" asks past its cache. -->
<script setup lang="ts">
import { ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import Card from "../components/ui/Card.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Tabs from "../components/ui/Tabs.vue";
import CaddyTab from "./gelismis/CaddyTab.vue";
import DnsTab from "./gelismis/DnsTab.vue";
import PodmanTab from "./gelismis/PodmanTab.vue";
import { readAdvanced, type Advanced } from "../api/gelismis";
import { ADVANCED_TABS, type AdvancedTab } from "../sections";
import { useQueryParam } from "../query";
import { clock } from "../format";

const TABS = ADVANCED_TABS.map((t) => ({ id: t.id, label: t.label }));

const data = ref<Advanced | null>(null);
const error = ref("");
const loading = ref(false);
let asked = false;

async function load(fresh = false): Promise<void> {
  asked = true;
  loading.value = true;
  try {
    data.value = await readAdvanced(fresh);
    error.value = "";
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}
// Caddy and DNS read the configuration the first time one of them is shown.
const tab = useQueryParam<AdvancedTab>("sekme", ADVANCED_TABS.map((t) => t.id), "caddy");
watch(tab, (id) => {
  if ((id === "caddy" || id === "dns") && !asked) void load();
}, { immediate: true });

const firewall = "/erisim?sekme=guvenlik-duvari";
</script>

<template>
  <div class="page-body advanced-page">
    <Tabs :tabs="TABS" label="Gelişmiş bölümleri" param="sekme">
      <template #default="{ active }">
        <template v-if="active === 'caddy' || active === 'dns'">
          <div class="advanced-tools">
            <span class="meter-note" data-testid="advanced-read">{{ data?.read_at ? `Son okuma ${clock(data.read_at)}` : loading ? "Okunuyor…" : "" }}</span>
            <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="advanced-refresh" @click="load(true)">
              <Icon name="refresh" :size="16" />Yenile
            </button>
          </div>
          <p v-if="error" class="form-error" role="alert" data-testid="advanced-error">{{ error }}</p>
          <template v-if="data">
            <CaddyTab v-if="active === 'caddy'" :data="data" />
            <DnsTab v-else :data="data" />
          </template>
          <section v-else-if="!error" class="card" aria-label="Yapılandırma">
            <EmptyState title="Yapılandırma okunuyor" icon="sliders" />
          </section>
        </template>
        <div v-else-if="active === 'guvenlik-duvari'" class="advanced-tab" data-testid="advanced-firewall">
          <Card title="Güvenlik duvarı kuralları">
            <p class="card-text">
              Güvenlik duvarının canlı kuralları (INPUT, FORWARD ve NAT dahil her tablo), sayaçları, sahipleri ve dinleyiciler Erişim → Güvenlik
              duvarı'ndadır. Port izinleri de orada, plan ve süreli onayla değiştirilir; aynı şey burada tekrarlanmaz.
            </p>
            <div class="action-line">
              <RouterLink :to="firewall + '&kurallar=1'" class="btn btn-primary" data-testid="firewall-rules">
                <Icon name="shield" :size="16" />Teknik kuralları aç
              </RouterLink>
              <RouterLink :to="firewall" class="btn btn-secondary" data-testid="firewall-ports">Port izinleri</RouterLink>
            </div>
          </Card>
        </div>
        <PodmanTab v-else-if="active === 'podman'" />
      </template>
    </Tabs>
  </div>
</template>
