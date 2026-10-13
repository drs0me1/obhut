<!-- Phase 1 (DD-258): every section is a placeholder that leads to the current interface; Sistem also holds
     the theme choice. -->
<script setup lang="ts">
import { computed } from "vue";
import { useRoute } from "vue-router";
import { Icon } from "../components/icons";
import ThemeControl from "../components/ThemeControl.vue";
import { sectionById } from "../sections";

const route = useRoute();
const section = computed(() => sectionById(route.name));
</script>

<template>
  <div class="page-body">
    <section class="card" aria-label="Eski Konsol" data-testid="legacy">
      <p class="card-text">Bu bölüm yeni arayüzde hazırlanıyor. Şimdilik eski Konsol'da:</p>
      <ul class="link-row">
        <li v-for="link in section.legacy" :key="link.href">
          <a class="btn btn-secondary" :href="link.href">
            {{ link.label }}
            <Icon name="open" :size="16" />
          </a>
        </li>
      </ul>
    </section>
    <section v-if="section.id === 'sistem'" class="card" aria-labelledby="gorunum-baslik">
      <h2 id="gorunum-baslik" class="card-title">Görünüm</h2>
      <ThemeControl />
    </section>
  </div>
</template>
