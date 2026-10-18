<!-- Uyarılar (#/uyarilar): everything that needs the operator, in one place behind the top bar's count
     (problems.ts: a health check → Sistem → Sağlık, an Erişim warning → its access row, tab or application, an
     application that does not run fully or has a newer image → its page), the most serious first, each with the
     link to where it is fixed; or the calm state. Genel Bakış carries no such card: the count in the top bar is the
     one place that says how many, this page the one place that lists them. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import { checkLevel, live, serverNow } from "../live";
import { problemList, problemSummary } from "../problems";
import { systemRoute } from "../sections";
import { usePageHead } from "../page";
import { since } from "../format";

const now = ref(serverNow());
let clockTimer: number | undefined;
onMounted(() => {
  clockTimer = window.setInterval(() => (now.value = serverNow()), 30000);
});
onBeforeUnmount(() => clearInterval(clockTimer));
// "son denetim …" follows the server's clock as soon as it is known.
watch(() => live.offset, () => (now.value = serverNow()));

const calm = computed(() => {
  const s = live.saglik;
  if (!s) return { known: false, sub: "Denetimlerin sonucu henüz gelmedi." };
  return { known: true, sub: `${s.checks.filter((c) => checkLevel(c.status) === "ok").length} denetim sorunsuz · son denetim ${since(s.read_at, now.value)}` };
});
const SEV_ICON: Record<"danger" | "warning" | "accent", "xcircle" | "alert" | "update"> = { danger: "xcircle", warning: "alert", accent: "update" };

/** The head's line: how many need attention and how much is news. */
const description = computed(() => {
  const p = problemSummary.value;
  if (!p) return "Sunucunun durumu okunuyor.";
  const news = problemList.value.length - p.count;
  const parts = [p.count ? `${p.count} konu dikkat istiyor` : "Dikkat isteyen konu yok"];
  if (news) parts.push(`${news} haber`);
  return parts.join(" · ");
});
usePageHead(() => ({ title: "Uyarılar", description: description.value }));
</script>

<template>
  <div class="page-body problems-page">
    <section class="card" aria-labelledby="uyari-baslik" data-testid="problems-card">
      <template v-if="problemList.length">
        <div class="card-head">
          <h2 id="uyari-baslik" class="card-title">Dikkat · {{ problemList.length }}</h2>
          <RouterLink class="btn btn-secondary btn-sm" :to="systemRoute('saglik')">Tüm denetimler</RouterLink>
        </div>
        <ul class="problems" aria-label="Dikkat isteyen konular">
          <li v-for="p in problemList" :key="p.key" class="problem" :class="'problem-' + p.tone" :data-kind="p.kind">
            <span class="sev" :class="'sev-' + p.tone" aria-hidden="true"><Icon :name="SEV_ICON[p.tone]" :size="18" /></span>
            <div class="problem-text">
              <strong>{{ p.title }}</strong>
              <span v-if="p.detail">{{ p.detail }}</span>
            </div>
            <RouterLink :to="p.to" class="btn btn-secondary btn-sm" data-eylem="duzelt">{{ p.label }}</RouterLink>
          </li>
        </ul>
      </template>
      <div v-else class="calm">
        <span class="sev" :class="calm.known ? 'sev-ok' : 'sev-neutral'" aria-hidden="true"><Icon :name="calm.known ? 'check' : 'unknown'" :size="20" /></span>
        <div class="calm-text">
          <h2 id="uyari-baslik" class="card-title">{{ calm.known ? "Her şey yolunda" : "Sağlık durumu okunuyor" }}</h2>
          <p class="meter-note" data-testid="health-sub">{{ calm.sub }}</p>
        </div>
        <RouterLink class="btn btn-secondary btn-sm" :to="systemRoute('saglik')">Tüm denetimler</RouterLink>
      </div>
    </section>
  </div>
</template>
