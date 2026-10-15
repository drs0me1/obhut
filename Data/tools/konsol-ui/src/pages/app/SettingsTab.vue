<!-- An application's Ayarlar (phase 4a; DD-258: one place per setting). From what the backend declares, never
     from the application's name: a Konsol container's definition (DefinitionEditor), an App Store package's
     container settings when its adapter lets fields change (AdapterEditor), its settings form when its
     konsol.json form names `oku` and `yaz` (PackageSettings; fields the adapter card edits are left out of
     it), and its first-login account when it has one (AccountCard). A container made outside Konsol is
     adopted first; a VPN package's networks are on Erişim's WireGuard tab; a built-in still has its page in
     the current interface. -->
<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import AccountCard from "../uygulama/AccountCard.vue";
import AdapterEditor from "../uygulama/AdapterEditor.vue";
import DefinitionEditor from "../uygulama/DefinitionEditor.vue";
import PackageSettings from "../uygulama/PackageSettings.vue";
import { formOf } from "../uygulama/form";
import { message } from "../uygulama/flows";
import { readPackages } from "../../api/uygulama";
import { legacyPage } from "../../apps";
import { accessRoute, addRoute } from "../../sections";
import type { AdapterConfig, ContainerConfig, ContainerDetail } from "../../api/podman";
import type { Modul, Uygulama } from "../../api/sema";

const props = defineProps<{ app: Uygulama; box: ContainerDetail | null; boxLoading: boolean }>();
const emit = defineEmits<{ changed: []; reload: [] }>();

const isPackage = computed(() => props.app.tur === "paket" && Boolean(props.app.modul));
const module = ref<Modul | null>(null);
const moduleError = ref("");
const moduleRead = ref(false);
const noAccount = ref(false);

onMounted(async () => {
  if (!isPackage.value) return;
  try {
    module.value = (await readPackages()).find((m) => m.id === props.app.modul) ?? null;
  } catch (err) {
    moduleError.value = message(err);
  } finally {
    moduleRead.value = true;
  }
});

const definition = computed(() =>
  props.app.tur === "konteyner" && props.box?.source === "konsol" && props.box.generic && props.box.actions.includes("save")
    ? (props.box as ContainerDetail & { generic: ContainerConfig })
    : null,
);
const adapter = computed(() =>
  props.box?.adapter && props.box.actions.includes("save") && props.box.editable.length ? (props.box as ContainerDetail & { adapter: AdapterConfig }) : null,
);
const form = computed(() => {
  const f = formOf(module.value?.konsol);
  return f && f.oku && f.yaz ? f : null;
});
const omit = computed(() => (adapter.value ? adapter.value.editable : []));
const external = computed(() => props.box?.source === "external");
const legacy = computed(() => (props.app.tur === "yerlesik" ? legacyPage(props.app) : null));
// The VPN package's networks and devices are Erişim's WireGuard tab (as on its Erişim tab).
const vpn = computed(() => props.app.id === "paket:wireguard");
const pending = computed(() => props.boxLoading || (isPackage.value && !moduleRead.value));
const nothing = computed(() => !pending.value && !definition.value && !adapter.value && !form.value && (!isPackage.value || noAccount.value) && !external.value && !legacy.value && !vpn.value);
</script>

<template>
  <div class="settings-tab" data-testid="settings">
    <p v-if="moduleError" class="notice notice-warning" role="alert"><Icon name="alert" class="notice-icon" /><span>Paket bilgisi okunamadı: {{ moduleError }}</span></p>

    <DefinitionEditor v-if="definition" :box="definition" @saved="emit('changed')" @reload="emit('reload')" />

    <section v-else-if="external" class="card" aria-label="Ayarlar" data-testid="settings-external">
      <EmptyState title="Bu konteyner Konsol dışında yönetiliyor" :text="box?.restricted_reason || 'Ayarlarını burada değiştirmek için önce yönetime alın: Konsol onu kendi tanımıyla bir kez yeniden oluşturur.'" icon="lock">
        <RouterLink v-if="box?.actions.includes('adopt')" :to="addRoute('sahiplen', { ad: box.name })" class="btn btn-primary" data-testid="settings-adopt">Yönetime al</RouterLink>
      </EmptyState>
    </section>

    <section v-else-if="app.tur === 'konteyner' && box && !definition" class="card" aria-label="Ayarlar" data-testid="settings-locked">
      <EmptyState title="Bu konteynerin tanımı şu an düzenlenemiyor" :text="box.restricted_reason || 'Sunucu bu konteyner için kaydetmeye izin vermiyor.'" icon="lock" />
    </section>

    <AdapterEditor v-if="adapter" :box="adapter" @saved="emit('changed')" @reload="emit('reload')" />
    <PackageSettings v-if="form && app.modul" :package-id="app.modul" :form="form" :omit="omit" elsewhere="yukarıdaki Konteyner ayarları kartında değişir." @saved="emit('changed')" />
    <AccountCard v-if="isPackage" :app="app" @none="noAccount = true" />

    <Card v-if="vpn" title="Ağlar ve cihazlar" data-testid="settings-vpn">
      <p class="card-text">WireGuard ağları, cihazları ve DNS ayarı Erişim'in WireGuard bölümünde.</p>
      <RouterLink :to="accessRoute('wireguard')" class="btn btn-secondary fit">WireGuard ağları</RouterLink>
    </Card>

    <Card v-if="legacy" title="Ayarlar" data-testid="settings-legacy">
      <p class="card-text">{{ app.ad }} ayarları şimdilik eski Konsol'daki sayfasında; Dosyalar bölümü yapılınca buraya taşınacak.</p>
      <a class="btn btn-secondary fit" :href="legacy" data-testid="settings-link">Eski Konsol'da aç<Icon name="open" :size="16" /></a>
    </Card>

    <section v-if="nothing" class="card" aria-label="Ayarlar" data-testid="settings-empty">
      <EmptyState title="Bu uygulamanın ayrı bir ayar sayfası yok" icon="sliders" />
    </section>
    <p v-else-if="pending && !definition && !adapter" class="meter-note">Okunuyor…</p>
  </div>
</template>
