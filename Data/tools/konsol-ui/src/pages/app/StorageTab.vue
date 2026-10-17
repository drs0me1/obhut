<!-- An application's Depolama (rebuild phase 5; A5): every mount of every service with its target in the container,
     what it is (a folder of the application, a server folder under the Files account's area, or a tmpfs), its path
     on this server, whether it is read-only and, for an application folder, its size (Dosyalar → Depolama's
     measurement), each folder with the way to it in Dosyalar; and the application's own data folder. Read-only: a
     mount changes in Tanım. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import { relativePath } from "./answers";
import { filesRoute } from "../../sections";
import { live } from "../../live";
import { UNKNOWN, bytes } from "../../format";
import type { UygulamaAyrinti, UygulamaBaglamasi } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const KIND_TEXT: Record<UygulamaBaglamasi["tur"], string> = { app: "Uygulamanın klasörü", srv: "Sunucu klasörü · Dosyalar hesabı", tmpfs: "Geçici (bellekte)" };
const root = computed(() => live.kaynaklar?.root ?? "");
const systemPath = (path: string) => filesRoute("sistem", { yol: path.replace(/^\/+/, "") });
const mounts = computed(() =>
  props.detail.servisler.flatMap((s) =>
    s.baglamalar.map((m) => {
      const rel = m.tur === "srv" ? relativePath(m.yol, root.value) : "";
      const to = m.tur === "app" && m.yol ? systemPath(m.yol) : m.tur === "srv" && rel ? filesRoute("srv", { yol: rel }) : "";
      return {
        key: `${s.ad}:${m.hedef}`,
        service: s.ad,
        m,
        access: m.tur === "tmpfs" ? UNKNOWN : m.salt_okunur ? "Salt okunur" : "Okuma-yazma",
        size: m.tur === "app" && typeof m.boyut === "number" ? bytes(m.boyut) : UNKNOWN,
        to,
        link: m.tur === "app" ? "Sistem dosyaları'nda aç" : "Dosyalar'da aç",
      };
    }),
  ),
);
</script>

<template>
  <div class="storage-tab">
    <section class="card table-card" aria-labelledby="baglama-baslik" data-testid="mounts">
      <h2 id="baglama-baslik" class="card-title">Bağlamalar</h2>
      <div v-if="mounts.length" class="table-wrap">
        <table class="data-table" data-testid="mount-table">
          <thead>
            <tr>
              <th scope="col">Konteynerde</th>
              <th scope="col">Sunucuda</th>
              <th scope="col">İzin</th>
              <th scope="col">Boyut</th>
              <th scope="col"><span class="sr-only">Klasör</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="x in mounts" :key="x.key" :data-hedef="x.key">
              <th scope="row" class="col-main">
                <strong class="mono wrap">{{ x.m.hedef }}</strong>
                <span class="cell-sub">{{ x.service }}</span>
              </th>
              <td data-label="Sunucuda">
                <span class="cell-stack">
                  <span v-if="x.m.yol" class="mono wrap">{{ x.m.yol }}</span>
                  <span class="cell-note">{{ KIND_TEXT[x.m.tur] ?? x.m.tur }}</span>
                </span>
              </td>
              <td data-label="İzin">{{ x.access }}</td>
              <td data-label="Boyut" class="nowrap" data-testid="mount-size">{{ x.size }}</td>
              <td class="col-act">
                <RouterLink v-if="x.to" :to="x.to" class="btn btn-secondary btn-sm" :aria-label="`${x.m.hedef}: ${x.link}`">{{ x.link }}</RouterLink>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="Bu uygulamaya bağlı klasör yok" icon="folder" />
    </section>
    <Card title="Uygulamanın verileri" data-testid="data-folder">
      <p class="mono wrap" data-testid="data-path">{{ detail.veri }}</p>
      <p class="meter-note">Uygulamanın klasörleri burada durur. Kaldırırken verilerin saklanması sorulur (saklamak varsayılan); sunucu klasörlerine (/srv) hiçbir durumda dokunulmaz.</p>
      <div><RouterLink :to="systemPath(detail.veri)" class="btn btn-secondary btn-sm">Sistem dosyaları'nda aç</RouterLink></div>
    </Card>
  </div>
</template>
