<!-- An application's Ayarlar: in phase 2 still on its page in the current interface (DD-258: one place per
     setting, so nothing is copied here before it moves). -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import { legacyPage } from "../../apps";
import type { Uygulama } from "../../api/sema";

const props = defineProps<{ app: Uygulama }>();
const page = computed(() => legacyPage(props.app));
</script>

<template>
  <Card v-if="page" title="Ayarlar" data-testid="settings">
    <p class="card-text">{{ app.ad }} uygulamasının ayarları şimdilik eski Konsol'daki sayfasında; sonraki aşamada buraya taşınacak.</p>
    <a class="btn btn-secondary fit" :href="page" data-testid="settings-link">Eski Konsol'da aç<Icon name="open" :size="16" /></a>
  </Card>
  <section v-else class="card" aria-label="Ayarlar" data-testid="settings">
    <EmptyState title="Bu uygulamanın ayrı bir ayar sayfası yok" icon="sliders" />
  </section>
</template>
