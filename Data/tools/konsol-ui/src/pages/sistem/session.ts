// The Konsol account and this browser's session (GET /api/konsol/oturum, DD-194/205), read once per page
// load and again after an account change. The backend names the channel (kanal); the page never guesses it
// from the address. The shell's "Çıkış yap" exists only for an open internet session: the tailnet address
// has no sign-in, the device is the credential.
import { computed, reactive } from "vue";
import { readSession, signOut } from "../../api/sistem";
import type { Oturum } from "../../api/sema";

export const session = reactive({
  value: null as Oturum | null,
  failed: false,
});

let inflight: Promise<void> | null = null;

/** Reads the session (an earlier read still under way is shared); `again` reads anew after a change. */
export function loadSession(again = false): Promise<void> {
  if (inflight && !again) return inflight;
  if (session.value && !again) return Promise.resolve();
  const read = readSession()
    .then((value) => {
      session.value = value;
      session.failed = false;
    })
    .catch(() => {
      session.failed = true;
    })
    .finally(() => {
      if (inflight === read) inflight = null;
    });
  inflight = read;
  return read;
}

/** The internet channel (the public HTTPS name): updates, repair, the reboot and the account creation
    are refused there. */
export const internetChannel = computed(() => session.value?.kanal === "internet");

/** An open session on the internet channel: the only case with something to sign out of. */
export const canSignOut = computed(() => session.value?.kanal === "internet" && session.value.durum === "acik");

/** Ends this browser's session and goes to the sign-in page, which returns to this interface. */
export async function leave(): Promise<void> {
  await signOut();
  location.replace("/giris.html");
}
