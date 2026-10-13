<!-- The shell (DD-258): sidebar, page head with the top bar's tools, the pending-change banner and the page;
     on a phone a compact top bar and a bottom bar instead of the sidebar. The palette, the activity drawer
     and the phone's menu sheet sit outside .app, which is inert while one of them is open. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink, RouterView, useRoute, useRouter } from "vue-router";
import SideNav from "./components/SideNav.vue";
import TopTools from "./components/TopTools.vue";
import PendingBanner from "./components/PendingBanner.vue";
import BottomBar from "./components/BottomBar.vue";
import CommandPalette from "./components/CommandPalette.vue";
import ActivityDrawer from "./components/ActivityDrawer.vue";
import MenuSheet from "./components/MenuSheet.vue";
import Wordmark from "./components/Wordmark.vue";
import { sectionById } from "./sections";
import { live } from "./live";
import { anyOpen, toggleSurface } from "./ui";

const route = useRoute();
const router = useRouter();
const section = computed(() => sectionById(route.name));
const heading = ref<HTMLElement | null>(null);
const main = ref<HTMLElement | null>(null);

watch(section, (s) => (document.title = `${s.title} · Konsol`), { immediate: true });
watch(anyOpen, (open) => document.documentElement.classList.toggle("modal-open", open));

// After moving to another page, focus its heading so a screen reader announces it.
const stopAfterEach = router.afterEach((to, from, failure) => {
  if (failure || !from.matched.length || to.path === from.path) return;
  void nextTick(() => heading.value?.focus({ preventScroll: true }));
});

function focusMain(): void {
  main.value?.focus();
}

function onKeydown(event: KeyboardEvent): void {
  if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && (event.code === "KeyK" || event.key.toLowerCase() === "k")) {
    event.preventDefault();
    toggleSurface("palette");
  }
}

onMounted(() => window.addEventListener("keydown", onKeydown));
onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
  stopAfterEach();
});
</script>

<template>
  <div class="app" :inert="anyOpen" :data-baglanti="live.connection">
    <a class="skip-link" href="#icerik" @click.prevent="focusMain">İçeriğe geç</a>
    <header class="sidebar">
      <SideNav />
    </header>
    <div class="column">
      <header class="mobile-top">
        <RouterLink to="/genel" class="mobile-brand" aria-label="Obhut · Genel Bakış">
          <Wordmark />
        </RouterLink>
        <TopTools compact />
      </header>
      <main id="icerik" ref="main" class="main" tabindex="-1">
        <div class="page-head">
          <div class="page-title">
            <h1 ref="heading" tabindex="-1">{{ section.title }}</h1>
            <p class="page-desc">{{ section.description }}</p>
          </div>
          <TopTools class="desktop-tools" />
        </div>
        <PendingBanner />
        <RouterView />
      </main>
    </div>
    <BottomBar />
  </div>
  <CommandPalette />
  <ActivityDrawer />
  <MenuSheet />
</template>
