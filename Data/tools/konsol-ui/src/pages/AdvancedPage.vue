<!-- Gelişmiş (DD-258; K8): the technical views, read-only; the only write is Podman's cleanup. Tabs in the address
     (?sekme=): Caddy (the effective sites and the raw files), DNS (dnsmasq's names and files), Güvenlik duvarı (the
     technical rules and the listeners) and Podman (the inventory and the cleanup). Caddy and DNS share one read of
     GET /api/konsol/gelismis; "Yenile" asks past its cache. Each view leads to where its source is changed. -->
<script setup lang="ts">
import { ref, watch } from "vue";
import { Icon } from "../components/icons";
import EmptyState from "../components/ui/EmptyState.vue";
import Tabs from "../components/ui/Tabs.vue";
import CaddyTab from "./gelismis/CaddyTab.vue";
import DnsTab from "./gelismis/DnsTab.vue";
import PodmanTab from "./gelismis/PodmanTab.vue";
import RulesTab from "./gelismis/RulesTab.vue";
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
        <RulesTab v-else-if="active === 'guvenlik-duvari'" />
        <PodmanTab v-else-if="active === 'podman'" />
      </template>
    </Tabs>
  </div>
</template>
