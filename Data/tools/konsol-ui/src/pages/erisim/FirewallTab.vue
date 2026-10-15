<!-- Erişim → Güvenlik duvarı (as the current Settings page, console/ayarlar.js): the check, the incoming
     networks as tabs (?kapsam=: İnternet, Tailscale, WireGuard when a VPN is installed, Sunucu içi) and the
     address family (?aile=6). Rows are the baseline port catalogue merged with the operator's rules: port,
     protocol, name, whether something listens, the saved or draft state and the allow/deny switch (locked
     for the server's own ports and container publications). "+ Port kuralı" adds a rule. Edits are a draft →
     "İncele" → the plan → "Uygula" → the pending banner's 60 s confirmation. "Teknik kurallar" (?kurallar=1)
     shows the live iptables rows with their counters and owners, and the listeners. -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import Tabs from "../../components/ui/Tabs.vue";
import SettingsPlanSheet from "./SettingsPlanSheet.vue";
import { readFirewall } from "../../api/erisim";
import { live } from "../../live";
import { useLeaveGuard } from "../../leave";
import { useQueryFlag, useQueryParam } from "../../query";
import type { AyarIstegi, GuvenlikDuvari, KuralTaslagi } from "../../api/sema";

type Scope = "internet" | "tailscale" | "wireguard" | "sunucu";
const SCOPE_KEY: Record<Scope, "wan" | "tail" | "wg" | "lo"> = { internet: "wan", tailscale: "tail", wireguard: "wg", sunucu: "lo" };

const fw = ref<GuvenlikDuvari | null>(null);
const loadError = ref("");
const loading = ref(false);

async function load(fresh = false): Promise<void> {
  loading.value = true;
  try {
    fw.value = await readFirewall(fresh);
    loadError.value = "";
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}
onMounted(() => void load());
// The saved settings may have changed (a change ended or committed): read the rules again. A draft stays
// only while the saved rules it was made from are still the saved ones.
watch(() => live.ayarSurumu, async () => {
  const before = JSON.stringify(fw.value?.kurallar ?? null);
  await load(true);
  if (JSON.stringify(fw.value?.kurallar ?? null) !== before) draft.value = null;
});

const vpn = computed(() => fw.value?.vpn || "");
const TABS = computed(() => [
  { id: "internet", label: "İnternet" },
  { id: "tailscale", label: "Tailscale" },
  ...(vpn.value ? [{ id: "wireguard", label: vpn.value }] : []),
  { id: "sunucu", label: "Sunucu içi" },
]);
const FAMILIES = ["4", "6"] as const;
const family = useQueryParam<"4" | "6">("aile", FAMILIES, "4");
const technical = useQueryFlag("kurallar");
const locked = computed(() => Boolean(live.bekleyen));

// ---- the draft: the operator's rules as they would be saved
const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const saved = computed<KuralTaslagi[]>(() => fw.value?.kurallar ?? []);
const draft = ref<KuralTaslagi[] | null>(null);
const rules = computed<KuralTaslagi[]>(() => draft.value ?? saved.value);
const dirty = computed(() => draft.value !== null && !same(draft.value, saved.value));
// Closing or reloading the browser tab with a draft asks first (DD-266).
useLeaveGuard(dirty);

function edit(change: (rules: KuralTaslagi[]) => void): void {
  const next = clone(rules.value);
  change(next);
  draft.value = same(next, saved.value) ? null : next;
}

const changes = computed(() => {
  if (!dirty.value || !draft.value) return 0;
  const after = draft.value;
  let n = after.filter((r) => !same(r, saved.value.find((x) => x.id === r.id))).length;
  n += saved.value.filter((r) => !after.some((x) => x.id === r.id)).length;
  return n;
});

// ---- rows: the catalogue merged with the rules (a rule without a source takes over its catalogue row)
interface Row {
  key: string;
  name: string;
  family: number;
  scope: "wan" | "tail" | "lo";
  proto: string;
  port: number;
  rule: KuralTaslagi | null;
  fixed: boolean;
}

const allRows = computed<Row[]>(() => {
  const out: Row[] = (fw.value?.katalog ?? []).map((k, i) => ({
    key: `k${i}`, name: k.ad, family: k.aile, scope: k.kapsam, proto: k.proto, port: k.port, rule: null, fixed: k.sabit,
  }));
  for (const r of rules.value) {
    const found = out.find((x) => x.family === r.family && x.scope === r.scope && x.proto === r.proto && x.port === r.port && !x.rule && x.key.startsWith("k"));
    if (found && !r.source) {
      found.rule = r;
      continue;
    }
    out.push({ key: "r:" + r.id, name: r.name, family: r.family, scope: r.scope, proto: r.proto, port: r.port, rule: r, fixed: false });
  }
  return out;
});

function rowsOf(scope: Scope): Row[] {
  const key = SCOPE_KEY[scope];
  return allRows.value.filter((r) => r.scope === key && String(r.family) === family.value);
}

const savedOf = (row: Row) =>
  saved.value.find((x) => (row.rule ? x.id === row.rule.id : x.family === row.family && x.scope === row.scope && x.proto === row.proto && x.port === row.port && !x.source));
const allowOf = (row: Row) => (row.rule ? row.rule.allow : true);
function stateOf(row: Row): { badge: string; note: string; changed: boolean } {
  const s = savedOf(row);
  const changed = row.rule ? !same(row.rule, s) : Boolean(s);
  const note = changed ? (s ? `Kayıtlı: ${s.allow ? "izinli" : "engelli"}` : "Yeni kural") : "";
  return { badge: changed ? "Taslak" : row.rule ? "Kural" : "Temel", note, changed };
}

function setAllow(row: Row, on: boolean): void {
  edit((list) => {
    if (row.rule) {
      const r = list.find((x) => x.id === row.rule?.id);
      if (!r) return;
      // A switch's own rule turned back to the baseline (allow) and never saved goes away again.
      if (on && r.id.startsWith("p_") && !saved.value.some((x) => x.id === r.id)) list.splice(list.indexOf(r), 1);
      else r.allow = on;
    } else {
      list.push({ id: `p_${row.family}_${row.scope}_${row.proto}_${row.port}`, name: row.name.slice(0, 64), family: row.family, scope: row.scope as "wan" | "tail",
        proto: row.proto as "tcp" | "udp", port: row.port, source: "", allow: on });
    }
  });
}

function removeRule(row: Row): void {
  edit((list) => {
    const i = list.findIndex((x) => x.id === row.rule?.id);
    if (i >= 0) list.splice(i, 1);
  });
}

// ---- listeners
function listening(row: Row): string {
  const list = fw.value?.dinleyiciler;
  if (list == null) return "Okunamadı";
  const binds = list.filter((b) => b.port === row.port && b.proto === row.proto && b.aile === row.family);
  if (!binds.length) return "Dinleyici yok";
  if (binds.some((b) => b.kapsam === "any" || b.kapsam === row.scope)) return row.scope === "lo" ? "Sunucu içinde dinliyor" : "Bu ağda dinliyor";
  if (binds.every((b) => b.kapsam === "lo")) return "Yalnız sunucu içinde";
  if (binds.some((b) => !b.kapsam || b.kapsam === "unknown")) return "Ağ eşleşmesi bilinmiyor";
  return "Başka adreste dinliyor";
}
const listenAddresses = (row: Row) =>
  [...new Set((fw.value?.dinleyiciler ?? []).filter((b) => b.port === row.port && b.proto === row.proto && b.aile === row.family).map((b) => b.adres))];

const DESCRIPTIONS: Record<Scope, string> = {
  internet: "İnternet arayüzünden gelen bağlantılar. SSH ve VPN bağlantı portları burada yer alır; listede olmayan portlar varsayılan olarak engellenir.",
  tailscale: "Tailscale ağından sunucuya gelen bağlantılar. Gerekli servisler ve tanımlı VPN portları izinlidir; diğer portlar bir kural açmadıkça engellenir.",
  wireguard: "",
  sunucu: "Sunucunun kendi iç bağlantıları (loopback). Servislerin arka uçları burada çalışır; bu izinler korunur ve değiştirilemez.",
};
const vpnText = computed(() =>
  `${vpn.value} cihazları yalnız internete çıkar. Sunucu servisleri, özel ağlar ve diğer cihazlar engellenir; bu politika değiştirilemez. ` +
  `${vpn.value}'in UDP bağlantı portu İnternet sekmesindedir; yönlendirme ve NAT kuralları Teknik kurallar'dadır.`);

// ---- the rule form
const formOpen = ref(false);
const formEditing = ref<KuralTaslagi | null>(null);
const form = ref({ name: "", family: "4", scope: "wan" as "wan" | "tail", proto: "tcp" as "tcp" | "udp", port: "", source: "", allow: "true" });
const formTried = ref(false);

function openForm(rule: KuralTaslagi | null, scope: Scope): void {
  formEditing.value = rule;
  const s = scope === "tailscale" ? "tail" : "wan";
  form.value = rule
    ? { name: rule.name, family: String(rule.family), scope: rule.scope, proto: rule.proto, port: String(rule.port), source: rule.source, allow: String(rule.allow) }
    : { name: "", family: family.value, scope: s, proto: "tcp", port: "", source: "", allow: "true" };
  formTried.value = false;
  formOpen.value = true;
}

const formErrors = computed(() => {
  const f = form.value;
  const port = /^\d+$/.test(f.port.trim()) ? Number(f.port.trim()) : NaN;
  const name = f.name.trim();
  const source = f.source.trim();
  const errors = { name: "", port: "", source: "", clash: "" };
  if (!name || name.length > 64 || /[\u0000-\u001f\u007f]/.test(name)) errors.name = "1–64 karakterlik bir ad yazın.";
  if (!(port >= 1 && port <= 65535)) errors.port = "1 ile 65535 arasında bir port yazın.";
  if (source) {
    const v6 = source.includes(":");
    const shape = v6 ? /^[0-9a-f:.]+(\/\d{1,3})?$/i.test(source) : /^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(source);
    if (!shape) errors.source = "Bir IP adresi ya da CIDR yazın (ör. 203.0.113.0/24).";
    else if (v6 !== (f.family === "6")) errors.source = "Kaynak adresinin IP ailesi seçilen aileyle uyuşmuyor.";
  }
  const clash = rules.value.find((x) => x.id !== formEditing.value?.id && x.family === Number(f.family) && x.scope === f.scope && x.proto === f.proto && x.port === port && x.source === source);
  if (clash) errors.clash = "Bu port ve kaynak için zaten bir kural var; o satırı düzenleyin.";
  return errors;
});

function saveForm(): void {
  formTried.value = true;
  const e = formErrors.value;
  if (e.name || e.port || e.source || e.clash) return;
  const f = form.value;
  const editing = formEditing.value;
  const item: KuralTaslagi = {
    id: editing ? editing.id : "u_" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8),
    name: f.name.trim(), family: Number(f.family), scope: f.scope, proto: f.proto, port: Number(f.port.trim()), source: f.source.trim(), allow: f.allow === "true",
  };
  edit((list) => {
    const i = editing ? list.findIndex((x) => x.id === editing.id) : -1;
    if (i >= 0) list[i] = item;
    else list.push(item);
  });
  formOpen.value = false;
}

// ---- plan → apply
const planOpen = ref(false);
const request = computed<AyarIstegi | null>(() => (fw.value && draft.value ? { revision: fw.value.revizyon, firewall: clone(draft.value) } : null));
const planRequest = ref<AyarIstegi | null>(null);
function review(): void {
  if (!request.value) return;
  planRequest.value = request.value;
  planOpen.value = true;
}
function applied(): void {
  planOpen.value = false;
  draft.value = null;
}

// ---- technical rules
const technicalRows = computed(() => (fw.value?.teknik ?? []).filter((r) => String(r.aile) === family.value));
const listeners = computed(() => (fw.value?.dinleyiciler ?? []).filter((r) => String(r.aile) === family.value));
const SCOPE_TEXT: Record<string, string> = { wan: "İnternet", tail: "Tailscale", lo: "Sunucu içi", any: "Tüm arayüzler", wg: "VPN" };
const number = (n: number) => n.toLocaleString("tr-TR");
function onTechnical(event: Event): void {
  technical.value = (event.target as HTMLDetailsElement).open;
}
</script>

<template>
  <div class="access-tab firewall" data-testid="firewall">
    <p v-if="loadError" class="form-error" role="alert">{{ loadError }}</p>
    <template v-if="fw">
      <div class="notice" :class="fw.denetim.ok ? 'notice-ok' : 'notice-warning'" role="note" data-testid="fw-check">
        <Icon :name="fw.denetim.ok ? 'check' : 'alert'" class="notice-icon" />
        <span>{{ fw.denetim.metin || (fw.denetim.ok ? "Güvenlik duvarı kuralları beklendiği gibi." : "Güvenlik duvarı denetimi uyardı.") }}</span>
      </div>
      <ul v-if="fw.hatalar.length" class="notice-list">
        <li v-for="(x, i) in fw.hatalar" :key="i" class="warn-text">{{ x }}</li>
      </ul>
      <p v-if="locked" class="notice" role="note" data-testid="fw-locked">
        <Icon name="clock" class="notice-icon" />
        <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar kurallar değiştirilemez.</span>
      </p>

      <div class="fw-tools">
        <div class="filters" role="group" aria-label="Adres ailesi">
          <button v-for="f in FAMILIES" :key="f" type="button" class="filter-chip" :aria-pressed="family === f" :data-aile="f" @click="family = f">IPv{{ f }}</button>
        </div>
        <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" @click="load(true)"><Icon name="refresh" :size="16" />Yenile</button>
      </div>

      <Tabs :tabs="TABS" label="Gelen ağlar" param="kapsam">
        <template #default="{ active }">
          <div class="fw-panel" :data-kapsam="active">
            <template v-if="active === 'wireguard'">
              <p class="card-text">{{ vpnText }}</p>
              <ul v-if="fw.aglar.length" class="fact-list" aria-label="VPN ağları">
                <li v-for="a in fw.aglar" :key="a.arayuz"><strong>{{ a.arayuz }}</strong><template v-if="a.ad"> · {{ a.ad }}</template> · {{ a.etkin ? "açık" : "durduruldu" }}</li>
              </ul>
              <p v-else class="meter-note">Henüz yönetilebilir bir {{ vpn }} ağı yok.</p>
            </template>
            <template v-else>
              <div class="fw-head">
                <p class="meter-note">{{ DESCRIPTIONS[active as Scope] }}</p>
                <button
                  v-if="active === 'internet' || active === 'tailscale'"
                  type="button"
                  class="btn btn-secondary btn-sm"
                  :disabled="locked"
                  data-testid="add-rule"
                  @click="openForm(null, active as Scope)"
                >
                  <Icon name="plus" :size="16" />Port kuralı
                </button>
              </div>
              <div v-if="rowsOf(active as Scope).length" class="table-wrap">
                <table class="data-table fw-table">
                  <thead>
                    <tr>
                      <th scope="col">Hizmet</th>
                      <th scope="col">Port</th>
                      <th scope="col">Kaynak</th>
                      <th scope="col">Dinleme</th>
                      <th scope="col">Durum</th>
                      <th scope="col">İzin</th>
                      <th scope="col"><span class="sr-only">Eylemler</span></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      v-for="r in rowsOf(active as Scope)"
                      :key="r.key"
                      :class="{ 'row-changed': stateOf(r).changed }"
                      :data-kural="r.rule?.id ?? ''"
                      :data-port="`${r.proto}/${r.port}`"
                    >
                      <th scope="row" class="col-main">
                        <strong>{{ r.name.split(" — ")[0] }}</strong>
                        <span class="cell-sub">IPv{{ r.family }}</span>
                      </th>
                      <td data-label="Port"><span class="mono">{{ r.port }}</span> {{ r.proto.toUpperCase() }}</td>
                      <td data-label="Kaynak"><span :class="{ mono: r.rule?.source }">{{ r.rule?.source || "Tüm kaynaklar" }}</span></td>
                      <td data-label="Dinleme">
                        <span class="cell-stack">
                          <span>{{ listening(r) }}</span>
                          <span v-for="a in listenAddresses(r)" :key="a" class="mono cell-note">{{ a }}</span>
                        </span>
                      </td>
                      <td data-label="Durum">
                        <span class="cell-stack">
                          <StatusPill :tone="allowOf(r) ? 'ok' : 'danger'">{{ allowOf(r) ? "İzinli" : "Engelli" }}</StatusPill>
                          <span class="cell-note" :class="{ 'warn-text': stateOf(r).changed }" data-testid="rule-state">{{ stateOf(r).badge }}<template v-if="stateOf(r).note"> · {{ stateOf(r).note }}</template></span>
                        </span>
                      </td>
                      <td data-label="İzin">
                        <Switch
                          :model-value="allowOf(r)"
                          :label="`${r.name} ${r.proto.toUpperCase()} ${r.port} izni`"
                          hide-label
                          :disabled="locked || r.scope === 'lo' || r.fixed"
                          @update:model-value="setAllow(r, $event)"
                        />
                        <span v-if="r.scope === 'lo'" class="cell-note">Sunucu içi · korunur</span>
                        <span v-else-if="r.fixed" class="cell-note">Konteyner yayını · uygulamayla açılır, kapanır</span>
                      </td>
                      <td class="col-act">
                        <span v-if="r.rule" class="row-actions">
                          <button type="button" class="btn btn-secondary btn-sm" :disabled="locked" :aria-label="`${r.name} kuralını düzenle`" @click="openForm(r.rule, active as Scope)">Düzenle</button>
                          <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="locked" :aria-label="`${r.name} kuralını kaldır`" @click="removeRule(r)">Kaldır</button>
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <EmptyState v-else title="Bu seçimde port yok" icon="shield" />
              <p class="meter-note">Dinleme ve izin ayrıdır: bir servisin bu ağda dinlemesi erişim garantisi değildir. Anahtar yalnız yeni bağlantıların iznini değiştirir; açık bağlantılar korunur.</p>
            </template>
          </div>
        </template>
      </Tabs>

      <details class="card technical-card" :open="technical" data-testid="fw-technical" @toggle="onTechnical">
        <summary>Teknik kurallar</summary>
        <p class="meter-note">Tüm ağlar · INPUT, FORWARD ve NAT dahil tüm tablolar · IPv{{ family }}. Kurallar zincir içindeki sırayla değerlendirilir; sayaçlar son okumanın değeridir. Salt okunur.</p>
        <div class="table-wrap">
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
              <tr v-for="(t, i) in technicalRows" :key="i">
                <th scope="row" class="col-main"><strong>{{ t.zincir }}</strong><span class="cell-sub">{{ t.tablo }} · IPv{{ t.aile }}</span></th>
                <td data-label="Sıra">{{ t.sira }}</td>
                <td data-label="Kural"><code class="rule-spec">{{ t.kural }}</code></td>
                <td data-label="Sayaç">{{ number(t.paket) }} paket · {{ number(t.bayt) }} bayt</td>
                <td data-label="Sahibi">{{ t.sahip }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-if="!technicalRows.length" class="meter-note">Bu ailede okunan kural yok.</p>
        <h3 class="plan-title">Dinleyiciler</h3>
        <p v-if="fw.dinleyiciler === null" class="meter-note">Dinleyiciler okunamadı.</p>
        <div v-else class="table-wrap">
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
                <td data-label="Adres" class="mono">{{ l.adres }}</td>
                <td data-label="Ağ">{{ SCOPE_TEXT[l.kapsam] ?? l.kapsam }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>

      <div v-if="dirty" class="draft-bar" role="region" aria-label="Taslak" data-testid="fw-draft">
        <div>
          <strong>{{ changes }} değişiklik taslakta</strong>
          <span class="meter-note">İnceleyip uygulayana kadar sunucu değişmez; uygulayınca 60 saniye içinde onaylamanız gerekir.</span>
        </div>
        <div class="draft-actions">
          <button type="button" class="btn btn-secondary" @click="draft = null">Vazgeç</button>
          <button type="button" class="btn btn-primary" :disabled="locked" data-testid="review-fw" @click="review">İncele</button>
        </div>
      </div>
    </template>
    <section v-else-if="!loadError" class="card" aria-label="Güvenlik duvarı">
      <EmptyState title="Güvenlik duvarı okunuyor" icon="shield" />
    </section>

    <SettingsPlanSheet
      :open="planOpen"
      title="Güvenlik duvarı değişiklikleri"
      description="Uygulayınca kurallar yeniden kurulur; bağlantınız çalışıyorsa onaylayın."
      :request="planRequest"
      @close="planOpen = false"
      @applied="applied"
    />

    <Modal :open="formOpen" variant="sheet" :title="formEditing ? 'Kuralı düzenle' : 'Port kuralı ekle'" description="İnternet ya da Tailscale'den gelen bir port için izin ya da engel." @close="formOpen = false">
      <form id="kural-formu" class="form-stack" novalidate @submit.prevent="saveForm">
        <Field v-slot="{ id, describedby, invalid }" label="Ad" :error="formTried ? formErrors.name : ''">
          <input :id="id" v-model="form.name" class="input" type="text" maxlength="64" autocomplete="off" placeholder="Medya sunucusu"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
        </Field>
        <div class="form-row">
          <Field v-slot="{ id }" label="Ağ">
            <select :id="id" v-model="form.scope" class="input">
              <option value="wan">İnternet</option>
              <option value="tail">Tailscale</option>
            </select>
          </Field>
          <Field v-slot="{ id }" label="Adres ailesi">
            <select :id="id" v-model="form.family" class="input">
              <option value="4">IPv4</option>
              <option value="6">IPv6</option>
            </select>
          </Field>
        </div>
        <div class="form-row">
          <Field v-slot="{ id }" label="Protokol">
            <select :id="id" v-model="form.proto" class="input">
              <option value="tcp">TCP</option>
              <option value="udp">UDP</option>
            </select>
          </Field>
          <Field v-slot="{ id, describedby, invalid }" label="Port" :error="formTried ? formErrors.port : ''">
            <input :id="id" v-model="form.port" class="input" type="text" inputmode="numeric" maxlength="5" autocomplete="off" placeholder="8096"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
          </Field>
        </div>
        <Field v-slot="{ id, describedby, invalid }" label="Kaynak IP / CIDR" optional hint="Boş bırakılırsa bu ağdaki tüm kaynaklar." :error="formTried ? formErrors.source : ''">
          <input :id="id" v-model="form.source" class="input" type="text" maxlength="64" autocomplete="off" spellcheck="false" placeholder="203.0.113.0/24"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <Field label="Eylem" group>
          <label class="check-row"><input v-model="form.allow" type="radio" name="kural-eylem" value="true" /><span>İzin ver</span></label>
          <label class="check-row"><input v-model="form.allow" type="radio" name="kural-eylem" value="false" /><span>Engelle</span></label>
        </Field>
        <p v-if="formTried && formErrors.clash" class="form-error" role="alert">{{ formErrors.clash }}</p>
        <p class="meter-note">İzin vermek servisin dinlediği adresi değiştirmez. İlk eşleşen kural geçerlidir. Kural taslağa yazılır; İncele ile uygulanır.</p>
      </form>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="formOpen = false">Vazgeç</button>
        <button type="submit" form="kural-formu" class="btn btn-primary" data-testid="save-rule">Taslağa yaz</button>
      </template>
    </Modal>
  </div>
</template>
