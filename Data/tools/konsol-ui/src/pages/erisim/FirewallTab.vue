<!-- Erişim → Güvenlik duvarı (rebuild phase 5): the incoming networks (?kapsam=: İnternet, Tailscale, WireGuard when
     it has networks, Yalnız bu sunucu) and the address family (?aile=6). Rows are the base's ports (`portlar`)
     merged with the operator's rules: the service, its port (with a rule's source), where the row comes from
     (Temel, Adresler, Elle) and its permission: a switch for the base's ports and the operator's rules, a lock for
     the server's own loopback ports and for an application's raw and Tailscale ports, whose row in Erişim →
     Adresler they link to. "Port kuralı" adds a rule. Edits are a draft → "İncele" → the plan → "Uygula" → the
     pending banner's 60 s confirmation. The live iptables rules and the listeners are Gelişmiş's ("Teknik
     kurallar"). -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import Switch from "../../components/ui/Switch.vue";
import SettingsPlanSheet from "./SettingsPlanSheet.vue";
import { readFirewall } from "../../api/erisim";
import { live } from "../../live";
import { accessRoute, advancedRoute } from "../../sections";
import { useLeaveGuard } from "../../leave";
import { useQueryParam } from "../../query";
import type { AyarIstegi, GuvenlikDuvari, KuralTaslagi } from "../../api/sema";

type Scope = "internet" | "tailscale" | "wireguard" | "sunucu";
const SCOPE_KEY: Record<Scope, "wan" | "tail" | "wg" | "lo"> = { internet: "wan", tailscale: "tail", wireguard: "wg", sunucu: "lo" };

const fw = ref<GuvenlikDuvari | null>(null);
const loadError = ref("");

async function load(fresh = false): Promise<void> {
  try {
    fw.value = await readFirewall(fresh);
    loadError.value = "";
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err);
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

const SCOPES = computed(() => [
  { id: "internet" as const, label: "İnternet" },
  { id: "tailscale" as const, label: "Tailscale" },
  ...(fw.value?.aglar.length ? [{ id: "wireguard" as const, label: "WireGuard" }] : []),
  { id: "sunucu" as const, label: "Yalnız bu sunucu" },
]);
const scope = useQueryParam<Scope>("kapsam", () => SCOPES.value.map((s) => s.id), "internet");
const FAMILIES = ["4", "6"] as const;
const family = useQueryParam<"4" | "6">("aile", FAMILIES, "4");
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

// ---- rows: the base's ports merged with the rules (a rule without a source takes over its port's row)
interface Row {
  key: string;
  name: string;
  family: number;
  scope: "wan" | "tail" | "lo";
  proto: string;
  port: number;
  rule: KuralTaslagi | null;
  fixed: boolean;
  /** A fixed row's access row (an application's raw or Tailscale port). */
  satir: string | null;
}

const allRows = computed<Row[]>(() => {
  const out: Row[] = (fw.value?.portlar ?? []).map((k, i) => ({
    key: `k${i}`, name: k.ad, family: k.aile, scope: k.kapsam, proto: k.proto, port: k.port, rule: null, fixed: k.sabit, satir: k.satir,
  }));
  for (const r of rules.value) {
    const found = out.find((x) => x.family === r.family && x.scope === r.scope && x.proto === r.proto && x.port === r.port && !x.rule && !x.fixed && x.key.startsWith("k"));
    if (found && !r.source) {
      found.rule = r;
      continue;
    }
    out.push({ key: "r:" + r.id, name: r.name, family: r.family, scope: r.scope, proto: r.proto, port: r.port, rule: r, fixed: false, satir: null });
  }
  return out;
});

const rows = computed(() => {
  const key = SCOPE_KEY[scope.value];
  return allRows.value.filter((r) => r.scope === key && String(r.family) === family.value);
});

const savedOf = (row: Row) =>
  saved.value.find((x) => (row.rule ? x.id === row.rule.id : x.family === row.family && x.scope === row.scope && x.proto === row.proto && x.port === row.port && !x.source));
const allowOf = (row: Row) => (row.rule ? row.rule.allow : true);
/** Where a row comes from: the base, an access row in Adresler, or the operator (Elle); and whether it is a draft. */
function originOf(row: Row): { text: string; note: string; changed: boolean } {
  const s = savedOf(row);
  const changed = row.rule ? !same(row.rule, s) : Boolean(s);
  if (changed) return { text: "Taslak", note: s ? `Kayıtlı: ${s.allow ? "izinli" : "engelli"}` : "Yeni kural", changed };
  if (row.satir) return { text: "Adresler", note: "", changed };
  return { text: row.rule ? "Elle" : "Temel", note: "", changed };
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

const DESCRIPTIONS: Record<Scope, string> = {
  internet: "İnternet arayüzünden gelen bağlantılar; listede olmayan portlar engellenir.",
  tailscale: "Tailscale ağından gelen bağlantılar; listede olmayan portlar bir kural açmadıkça engellenir.",
  wireguard: "WireGuard cihazları yalnız internete çıkar; sunucu servisleri, özel ağlar ve diğer cihazlar engellenir. Bu politika değiştirilemez.",
  sunucu: "Sunucunun kendi iç bağlantıları (loopback): servislerin arka uçları. Bu izinler korunur ve değiştirilemez.",
};

// ---- the rule form
const formOpen = ref(false);
const formEditing = ref<KuralTaslagi | null>(null);
const form = ref({ name: "", family: "4", scope: "wan" as "wan" | "tail", proto: "tcp" as "tcp" | "udp", port: "", source: "", allow: "true" });
const formTried = ref(false);

function openForm(rule: KuralTaslagi | null): void {
  formEditing.value = rule;
  const s = scope.value === "tailscale" ? "tail" : "wan";
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
</script>

<template>
  <div class="access-tab firewall" data-testid="firewall">
    <p v-if="loadError" class="form-error" role="alert">{{ loadError }}</p>
    <template v-if="fw">
      <div v-if="!fw.denetim.ok" class="notice notice-warning" role="note" data-testid="fw-check">
        <Icon name="alert" class="notice-icon" />
        <span>{{ fw.denetim.metin || "Güvenlik duvarı denetimi uyardı." }}</span>
      </div>
      <ul v-if="fw.hatalar.length" class="notice-list">
        <li v-for="(x, i) in fw.hatalar" :key="i" class="warn-text">{{ x }}</li>
      </ul>
      <p v-if="locked" class="notice" role="note" data-testid="fw-locked">
        <Icon name="clock" class="notice-icon" />
        <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar kurallar değiştirilemez.</span>
      </p>

      <section class="card table-card fw-card" aria-label="Güvenlik duvarı" :data-kapsam="scope">
        <div class="fw-tools">
          <span class="segmented" role="radiogroup" aria-label="Gelen ağ" data-testid="fw-scopes">
            <button v-for="s in SCOPES" :key="s.id" type="button" role="radio" class="segment" :aria-checked="scope === s.id" :data-kapsam="s.id" @click="scope = s.id">
              {{ s.label }}
            </button>
          </span>
          <span class="fw-actions">
            <span v-if="scope !== 'wireguard'" class="filters" role="group" aria-label="Adres ailesi">
              <button v-for="f in FAMILIES" :key="f" type="button" class="filter-chip" :aria-pressed="family === f" :data-aile="f" @click="family = f">IPv{{ f }}</button>
            </span>
            <button v-if="scope === 'internet' || scope === 'tailscale'" type="button" class="btn btn-secondary btn-sm" :disabled="locked" data-testid="add-rule" @click="openForm(null)">
              <Icon name="plus" :size="16" />Port kuralı
            </button>
            <RouterLink :to="advancedRoute('guvenlik-duvari')" class="btn btn-secondary btn-sm" data-testid="fw-technical">Teknik kurallar</RouterLink>
          </span>
        </div>
        <p class="meter-note">{{ DESCRIPTIONS[scope] }}</p>

        <ul v-if="scope === 'wireguard'" class="fact-list" aria-label="WireGuard ağları" data-testid="fw-wireguard">
          <li v-for="a in fw.aglar" :key="a.arayuz"><strong>{{ a.arayuz }}</strong><template v-if="a.ad"> · {{ a.ad }}</template> · {{ a.etkin ? "açık" : "kapalı" }}</li>
        </ul>
        <template v-else>
          <div v-if="rows.length" class="table-wrap">
            <table class="data-table fw-table">
              <thead>
                <tr>
                  <th scope="col">Hizmet</th>
                  <th scope="col">Port</th>
                  <th scope="col">Kaynak</th>
                  <th scope="col">İzin</th>
                  <th scope="col"><span class="sr-only">Eylemler</span></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  v-for="r in rows"
                  :key="r.key"
                  :class="{ 'row-changed': originOf(r).changed }"
                  :data-kural="r.rule?.id ?? ''"
                  :data-port="`${r.proto}/${r.port}`"
                >
                  <th scope="row" class="col-main"><strong>{{ r.name.split(" — ")[0] }}</strong></th>
                  <td data-label="Port" class="mono">{{ r.port }}/{{ r.proto }}<template v-if="r.rule?.source"> · {{ r.rule.source }}</template></td>
                  <td data-label="Kaynak">
                    <span class="cell-stack" data-testid="rule-origin">
                      <span :class="{ 'warn-text': originOf(r).changed }">{{ originOf(r).text }}</span>
                      <span v-if="originOf(r).note" class="cell-note">{{ originOf(r).note }}</span>
                    </span>
                  </td>
                  <td data-label="İzin">
                    <span v-if="r.scope === 'lo'" class="lock-line"><Icon name="lock" :size="14" />Korunur</span>
                    <RouterLink v-else-if="r.fixed && r.satir" :to="accessRoute('adresler', r.satir)" class="lock-line lock-link" data-testid="fw-row-link">
                      <Icon name="lock" :size="14" />Adresler'de yönet
                    </RouterLink>
                    <span v-else-if="r.fixed" class="lock-line"><Icon name="lock" :size="14" />Sabit</span>
                    <Switch
                      v-else
                      :model-value="allowOf(r)"
                      :label="`${r.name} ${r.proto.toUpperCase()} ${r.port} izni`"
                      hide-label
                      :disabled="locked"
                      @update:model-value="setAllow(r, $event)"
                    />
                  </td>
                  <td class="col-act">
                    <span v-if="r.rule" class="row-actions">
                      <button type="button" class="btn btn-secondary btn-sm" :disabled="locked" :aria-label="`${r.name} kuralını düzenle`" @click="openForm(r.rule)">Düzenle</button>
                      <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="locked" :aria-label="`${r.name} kuralını kaldır`" @click="removeRule(r)">Kaldır</button>
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="Bu seçimde port yok" icon="shield" />
        </template>
        <p class="meter-note">Adres ve doğrudan port satırlarının kuralları kendiliğinden gelir ve burada değiştirilemez; elle kurallar plan → uygula ve 60 sn onay ister.</p>
      </section>

      <div v-if="dirty" class="draft-bar" role="region" aria-label="Taslak" data-testid="fw-draft">
        <div>
          <strong>{{ changes }} değişiklik kaydedilmedi</strong>
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
