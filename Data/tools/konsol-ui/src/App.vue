<!-- The shell (DD-258): sidebar, page head with the top bar's tools, the pending-change banner and the page;
     on a phone a compact top bar and a bottom bar instead of the sidebar. The palette, the activity drawer,
     the phone's menu sheet, the Yayınla flow (?yayinla= on any page) and a page's dialogs sit outside .app,
     which is inert while one of them is open.
     A page below a section (an application) shows the trail back in the head and its own heading. -->
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
import PublishFlow from "./pages/erisim/PublishFlow.vue";
import Wordmark from "./components/Wordmark.vue";
import { Icon } from "./components/icons";
import { sectionById } from "./sections";
import { live } from "./live";
import { pageHead } from "./page";
import { anyOpen, toggleSurface, ui } from "./ui";

const route = useRoute();
const router = useRouter();
const section = computed(() => sectionById(route.meta.section ?? route.name));
const title = computed(() => pageHead.title ?? section.value.title);
const description = computed(() => pageHead.description ?? section.value.description);
const main = ref<HTMLElement | null>(null);

watch(title, (t) => (document.title = `${t} · Konsol`), { immediate: true });
watch(anyOpen, (open) => document.documentElement.classList.toggle("modal-open", open));

// After moving to another page, focus its heading so a screen reader announces it.
const stopAfterEach = router.afterEach((to, from, failure) => {
  if (failure || !from.matched.length || to.path === from.path) return;
  void nextTick(() => main.value?.querySelector<HTMLElement>("h1")?.focus({ preventScroll: true }));
});

function focusMain(): void {
  main.value?.focus();
}

function onKeydown(event: KeyboardEvent): void {
  if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && (event.code === "KeyK" || event.key.toLowerCase() === "k")) {
    event.preventDefault();
    // A confirmation waits for its answer; the palette does not replace it.
    if (ui.open !== "dialog") toggleSurface("palette");
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
        <div class="page-head" :class="{ 'page-head-trail': pageHead.parent }">
          <nav v-if="pageHead.parent" class="trail" aria-label="Konum">
            <RouterLink :to="pageHead.parent.to" class="trail-link">{{ pageHead.parent.label }}</RouterLink>
            <Icon name="chevron" :size="14" />
            <span aria-current="page">{{ title }}</span>
          </nav>
          <div v-else class="page-title">
            <h1 tabindex="-1">{{ title }}</h1>
            <p class="page-desc" data-testid="page-desc">{{ description }}</p>
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
  <PublishFlow />
</template>
