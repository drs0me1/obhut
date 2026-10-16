<!-- An application's Ayarlar (phase 4a; DD-258: one place per setting), from what the backend declares: a
     Konsol container's definition (DefinitionEditor). A container made outside Konsol is adopted first. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import EmptyState from "../../components/ui/EmptyState.vue";
import DefinitionEditor from "../uygulama/DefinitionEditor.vue";
import { addRoute } from "../../sections";
import type { ContainerConfig, ContainerDetail } from "../../api/podman";

const props = defineProps<{ box: ContainerDetail | null; boxLoading: boolean }>();
const emit = defineEmits<{ changed: []; reload: [] }>();

const definition = computed(() =>
  props.box?.source === "konsol" && props.box.generic && props.box.actions.includes("save")
    ? (props.box as ContainerDetail & { generic: ContainerConfig })
    : null,
);
const external = computed(() => props.box?.source === "external");
</script>

<template>
  <div class="settings-tab" data-testid="settings">
    <DefinitionEditor v-if="definition" :box="definition" @saved="emit('changed')" @reload="emit('reload')" />

    <section v-else-if="external" class="card" aria-label="Ayarlar" data-testid="settings-external">
      <EmptyState title="Bu konteyner Konsol dışında yönetiliyor" :text="box?.restricted_reason || 'Ayarlarını burada değiştirmek için önce yönetime alın: Konsol onu kendi tanımıyla bir kez yeniden oluşturur.'" icon="lock">
        <RouterLink v-if="box?.actions.includes('adopt')" :to="addRoute('sahiplen', { ad: box.name })" class="btn btn-primary" data-testid="settings-adopt">Yönetime al</RouterLink>
      </EmptyState>
    </section>

    <section v-else-if="box" class="card" aria-label="Ayarlar" data-testid="settings-locked">
      <EmptyState title="Bu konteynerin tanımı şu an düzenlenemiyor" :text="box.restricted_reason || 'Sunucu bu konteyner için kaydetmeye izin vermiyor.'" icon="lock" />
    </section>

    <p v-else-if="boxLoading" class="meter-note">Okunuyor…</p>

    <section v-else class="card" aria-label="Ayarlar" data-testid="settings-empty">
      <EmptyState title="Bu uygulamanın ayrı bir ayar sayfası yok" icon="sliders" />
    </section>
  </div>
</template>
