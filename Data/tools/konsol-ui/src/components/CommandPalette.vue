<!-- Command palette (DD-258): ⌘K / Ctrl+K or the search field. Pages (with the tabs of Erişim, Dosyalar,
     Sistem and Gelişmiş), the applications (each opens its own page) and actions ("Yayınla" among them),
     matched with Turkish case rules ("İŞ" finds "iş", "ıs" does not find "is"). A combobox
     over a listbox: focus stays in the field, ↑/↓ move, Enter opens, Esc closes. -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { Icon, type IconName } from "./icons";
import { trapTab } from "./focus";
import { ADD_FLOWS, SECTIONS, SECTION_TABS, accessRoute, addRoute } from "../sections";
import { apps } from "../live";
import { KIND_TEXT } from "../apps";
import { appRoute } from "../router";
import { THEMES, setTheme, theme, type ThemeChoice } from "../theme";
import { closeSurface, openSurface, ui } from "../ui";
import { fold } from "../format";

type Run = { kind: "route"; to: string } | { kind: "theme"; value: ThemeChoice } | { kind: "drawer" };

interface Item {
  key: string;
  group: string;
  label: string;
  hint: string;
  icon: IconName;
  words: string;
  run: Run;
}

const GROUPS = ["Sayfalar", "Uygulamalar", "Eylemler"] as const;

const router = useRouter();
const query = ref("");
const active = ref(0);
const field = ref<HTMLInputElement | null>(null);
const dialog = ref<HTMLElement | null>(null);
const open = computed(() => ui.open === "palette");

const items = computed<Item[]>(() => {
  const list: Item[] = [];
  for (const s of SECTIONS) {
    list.push({ key: "sayfa-" + s.id, group: "Sayfalar", label: s.title, hint: "Sayfa", icon: s.icon, words: s.keywords, run: { kind: "route", to: "/" + s.id } });
    // A section's tabs after the section (its first tab is the section's own page).
    for (const t of (SECTION_TABS[s.id] ?? []).slice(1)) {
      list.push({ key: `${s.id}-${t.id}`, group: "Sayfalar", label: `${s.title} → ${t.label}`, hint: s.title, icon: s.icon, words: t.keywords, run: { kind: "route", to: t.to } });
    }
  }
  for (const app of apps.value ?? []) {
    list.push({
      key: "uygulama-" + app.id,
      group: "Uygulamalar",
      label: app.ad,
      hint: "Uygulama",
      icon: "box",
      words: `${app.id} ${KIND_TEXT[app.tur]}`,
      run: { kind: "route", to: router.resolve(appRoute(app.id)).path },
    });
  }
  const themeWords: Record<ThemeChoice, string> = { sistem: "görünüm otomatik", acik: "görünüm aydınlık light", koyu: "görünüm karanlık dark" };
  for (const t of THEMES) {
    list.push({
      key: "tema-" + t.id,
      group: "Eylemler",
      label: "Tema: " + t.label,
      hint: theme.value === t.id ? "Seçili" : "Görünüm",
      icon: "theme",
      words: themeWords[t.id],
      run: { kind: "theme", value: t.id },
    });
  }
  list.push({
    key: "yayinla",
    group: "Eylemler",
    label: "Yayınla",
    hint: "Erişim",
    icon: "globe",
    words: "yayın adres alan adı internet tailscale https aç paylaş",
    run: { kind: "route", to: accessRoute("genel", "sec") },
  });
  for (const f of ADD_FLOWS) {
    list.push({ key: "ekle-" + f.id, group: "Eylemler", label: f.label, hint: "Uygulamalar", icon: "plus", words: f.keywords, run: { kind: "route", to: addRoute(f.id) } });
  }
  list.push({
    key: "islemler",
    group: "Eylemler",
    label: "Çalışan işlemleri göster",
    hint: "Etkinlik",
    icon: "pulse",
    words: "işlemler etkinlik görev",
    run: { kind: "drawer" },
  });
  return list;
});

const results = computed<Item[]>(() => {
  const tokens = fold(query.value).split(/\s+/).filter(Boolean);
  const found = tokens.length
    ? items.value.filter((item) => {
        const hay = fold(`${item.label} ${item.words} ${item.hint}`);
        return tokens.every((t) => hay.includes(t));
      })
    : items.value;
  return GROUPS.flatMap((g) => found.filter((item) => item.group === g));
});

const groups = computed(() => {
  const out: { name: string; items: { item: Item; index: number }[] }[] = [];
  results.value.forEach((item, index) => {
    let group = out.find((g) => g.name === item.group);
    if (!group) {
      group = { name: item.group, items: [] };
      out.push(group);
    }
    group.items.push({ item, index });
  });
  return out;
});

const optionId = (index: number) => `palet-secenek-${index}`;
const activeId = computed(() => (results.value.length ? optionId(active.value) : undefined));

watch(query, () => (active.value = 0));
// The list can change while open (an application installed meanwhile): keep the choice inside it.
watch(
  () => results.value.length,
  (n) => {
    if (active.value >= n) active.value = Math.max(0, n - 1);
  },
);
watch(open, (isOpen) => {
  if (!isOpen) return;
  query.value = "";
  active.value = 0;
  void nextTick(() => field.value?.focus());
});

function move(to: number): void {
  const n = results.value.length;
  if (!n) return;
  active.value = (to + n) % n;
  void nextTick(() => document.getElementById(optionId(active.value))?.scrollIntoView({ block: "nearest" }));
}

function choose(item: Item | undefined): void {
  if (!item) return;
  const run = item.run;
  if (run.kind === "theme") {
    setTheme(run.value);
    closeSurface();
  } else if (run.kind === "drawer") {
    openSurface("drawer");
  } else if (router.currentRoute.value.fullPath === run.to) {
    closeSurface();
  } else {
    closeSurface(false);
    void router.push(run.to);
  }
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    closeSurface();
  } else if (event.key === "ArrowDown") {
    event.preventDefault();
    move(active.value + 1);
  } else if (event.key === "ArrowUp") {
    event.preventDefault();
    move(active.value - 1);
  } else if (event.key === "Enter" && !event.isComposing) {
    event.preventDefault();
    choose(results.value[active.value]);
  } else if (event.key === "Tab") {
    trapTab(event, dialog.value);
  }
}
</script>

<template>
  <Transition name="fade">
    <div v-if="open" class="layer layer-palette" @keydown="onKeydown">
      <div class="scrim" aria-hidden="true" @click="closeSurface()"></div>
      <div ref="dialog" class="palette" role="dialog" aria-modal="true" aria-label="Komut paleti">
        <div class="palette-head">
          <Icon name="search" />
          <label for="palet-ara" class="sr-only">Sayfa, uygulama ya da işlem ara</label>
          <input
            id="palet-ara"
            ref="field"
            v-model="query"
            class="palette-input"
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls="palet-liste"
            aria-autocomplete="list"
            :aria-activedescendant="activeId"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder="Sayfa, uygulama ya da işlem ara"
          />
          <kbd>esc</kbd>
          <button type="button" class="icon-btn palette-close" aria-label="Kapat" @click="closeSurface()">
            <Icon name="close" />
          </button>
        </div>
        <div id="palet-liste" class="palette-list" role="listbox" aria-label="Sonuçlar">
          <div v-for="(g, gi) in groups" :key="g.name" role="group" :aria-labelledby="'palet-grup-' + gi" class="palette-group">
            <div :id="'palet-grup-' + gi" class="palette-group-name" role="presentation">{{ g.name }}</div>
            <div
              v-for="{ item, index } in g.items"
              :id="optionId(index)"
              :key="item.key"
              role="option"
              class="palette-option"
              :aria-selected="index === active"
              :data-key="item.key"
              @mousemove="active = index"
              @click="choose(item)"
            >
              <Icon :name="item.icon" :size="18" />
              <span class="palette-label">{{ item.label }}</span>
              <span class="palette-hint">{{ item.hint }}</span>
            </div>
          </div>
        </div>
        <p class="palette-empty" role="status">{{ results.length ? "" : "Sonuç yok. Başka bir sözcük deneyin." }}</p>
        <div class="palette-foot" aria-hidden="true"><span>↑↓ gezin</span><span>↵ aç</span><span>esc kapat</span></div>
      </div>
    </div>
  </Transition>
</template>
