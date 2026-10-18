<!-- Gelişmiş → Güvenlik duvarı (K8, A7): the technical rules as the kernel holds them (every table and chain the
     project and its neighbours write, in order, with their counters and owner) and the sockets this server listens
     on, per family (?aile=4|6), from GET /api/konsol/guvenlik-duvari ("Yenile" past its cache). Read-only: the
     operator's rules and every access row change in Erişim. -->
<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import { readFirewall } from "../../api/erisim";
import { accessRoute } from "../../sections";
import { useQueryParam } from "../../query";
import { clock } from "../../format";
import type { GuvenlikDuvari } from "../../api/sema";

const fw = ref<GuvenlikDuvari | null>(null);
const error = ref("");
const loading = ref(false);
const readAt = ref(0);

async function load(fresh = false): Promise<void> {
  loading.value = true;
  try {
    fw.value = await readFirewall(fresh);
    error.value = "";
    readAt.value = Date.now() / 1000;
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}
onMounted(() => void load());

const family = useQueryParam<"4" | "6">("aile", ["4", "6"], "4");
const FAMILIES = ["4", "6"] as const;
const rules = computed(() => (fw.value?.teknik ?? []).filter((r) => String(r.aile) === family.value));
const listeners = computed(() => (fw.value?.dinleyiciler ?? []).filter((r) => String(r.aile) === family.value));
const SCOPE_TEXT: Record<string, string> = { wan: "İnternet", tail: "Tailscale", lo: "Yalnız bu sunucu", any: "Tüm arayüzler", wg: "WireGuard" };
const number = (n: number) => n.toLocaleString("tr-TR");
</script>

<template>
  <div class="advanced-tab" data-testid="advanced-firewall">
    <div class="advanced-tools">
      <span class="filters" role="group" aria-label="Adres ailesi">
        <button v-for="f in FAMILIES" :key="f" type="button" class="filter-chip" :aria-pressed="family === f" :data-aile="f" @click="family = f">IPv{{ f }}</button>
      </span>
      <span class="meter-note" data-testid="fw-read">{{ readAt ? `Son okuma ${clock(readAt)}` : loading ? "Okunuyor…" : "" }}</span>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="fw-refresh" @click="load(true)">
        <Icon name="refresh" :size="16" />Yenile
      </button>
    </div>
    <p v-if="error" class="form-error" role="alert" data-testid="fw-error">{{ error }}</p>

    <section v-if="fw" class="card" aria-labelledby="teknik-baslik" data-testid="fw-technical">
      <div class="card-head">
        <h2 id="teknik-baslik" class="card-title">Teknik kurallar</h2>
        <div class="card-actions">
          <RouterLink :to="accessRoute('guvenlik-duvari')" class="btn btn-secondary btn-sm" data-testid="fw-manage">Erişim'de yönet</RouterLink>
        </div>
      </div>
      <p class="meter-note">
        Tüm ağlar · INPUT, FORWARD ve NAT dahil tüm tablolar · IPv{{ family }}. Kurallar zincir içindeki sırayla değerlendirilir; sayaçlar son
        okumanın değeridir. Salt okunur: kurallar Erişim'deki adreslerden, doğrudan portlardan ve port kurallarından üretilir.
      </p>
      <p v-for="(h, i) in fw.hatalar" :key="i" class="notice notice-warning" data-testid="fw-warning"><Icon name="alert" class="notice-icon" /><span>{{ h }}</span></p>
      <div v-if="rules.length" class="table-wrap">
        <table class="data-table tech-table">
          <thead>
            <tr>
              <th scope="col">Zincir</th>
              <th scope="col">Sıra</th>
              <th scope="col">Kural</th>
              <th scope="col">Sayaç</th>
              <th scope="col">Sahibi</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(t, i) in rules" :key="i" :data-zincir="t.zincir">
              <th scope="row" class="col-main"><strong>{{ t.zincir }}</strong><span class="cell-sub">{{ t.tablo }} · IPv{{ t.aile }}</span></th>
              <td data-label="Sıra">{{ t.sira }}</td>
              <td data-label="Kural"><code class="rule-spec">{{ t.kural }}</code></td>
              <td data-label="Sayaç">{{ number(t.paket) }} paket · {{ number(t.bayt) }} bayt</td>
              <td data-label="Sahibi">{{ t.sahip }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="Bu ailede okunan kural yok" icon="shield" />
    </section>

    <section v-if="fw" class="card" aria-labelledby="dinleyici-baslik" data-testid="fw-listeners">
      <h2 id="dinleyici-baslik" class="card-title">Dinleyiciler</h2>
      <p class="meter-note">Bu sunucuda dinleyen portlar. Dinlemek erişim demek değildir: izin yukarıdaki kurallardadır.</p>
      <p v-if="fw.dinleyiciler === null" class="notice notice-warning" data-testid="fw-listeners-error"><Icon name="alert" class="notice-icon" /><span>Dinleyiciler okunamadı.</span></p>
      <div v-else-if="listeners.length" class="table-wrap">
        <table class="data-table listen-table">
          <thead>
            <tr>
              <th scope="col">Port</th>
              <th scope="col">Adres</th>
              <th scope="col">Ağ</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(l, i) in listeners" :key="i">
              <th scope="row" class="col-main"><span class="mono">{{ l.port }}</span> {{ l.proto.toUpperCase() }}</th>
              <td data-label="Adres" class="mono wrap">{{ l.adres }}</td>
              <td data-label="Ağ">{{ SCOPE_TEXT[l.kapsam] ?? l.kapsam }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="Bu ailede dinleyen port yok" icon="shield" />
    </section>
    <section v-else-if="!error" class="card" aria-label="Güvenlik duvarı">
      <EmptyState title="Kurallar okunuyor" icon="shield" />
    </section>
  </div>
</template>
