#!/usr/bin/env python3
"""Konsol's live events (DD-259): one producer for every open event stream.

The producer runs only while a stream is open. It reads each topic on its own interval through a
function the backend passes in and publishes the topic again only when its content changed, so an
idle server sends nothing but heartbeats. Streams wait on one condition: the cost of a read does not
grow with the number of open tabs. A slow topic (the health card runs the firewall check) is read in
its own thread so it never holds up the others. Watchers (DD-294: Podman's event stream) run while the
producer does; one that saw a change nudges its topic, which is then read on the next tick instead of
waiting for its interval.
"""
import json
import threading
import time


class TooMany(Exception):
    """Every stream slot of the channel is taken; the page polls instead."""


class Topic:
    def __init__(self, name, every, read, key=None, slow=False):
        self.name, self.every, self.read, self.key, self.slow = name, every, read, key, slow


class Events:
    def __init__(self, topics, limit=4, clock=time.monotonic, tick=1.0, log=None, watchers=()):
        self.topics = list(topics)
        self.watchers = list(watchers)
        self.limit = limit
        self.clock = clock
        self.tick = tick
        self.log = log or (lambda message: print("panel: %s" % message, flush=True))
        self.cond = threading.Condition()
        self.clients = {}
        self.seq = 0
        self.latest = {}   # name -> (seq, comparison key, JSON text)
        self.due = {}
        self.busy = set()  # slow topics being read now
        self.failed = set()
        self.running = False
        self.thread = None

    # -- streams
    def subscribe(self, channel):
        """Takes a stream slot of the channel (Caddy keeps 16 connections per site to this backend,
        so streams must leave most of them to ordinary requests). Starts the producer if idle."""
        with self.cond:
            if self.clients.get(channel, 0) >= self.limit:
                raise TooMany()
            self.clients[channel] = self.clients.get(channel, 0) + 1
            if not self.running:
                self.running = True
                self.due, self.latest = {}, {}
                self.thread = threading.Thread(target=self.run, name="konsol-olaylar", daemon=True)
                self.thread.start()
                # Under the condition, so a stopping producer's watch(False) can never come after this start.
                self.watch(True)

    def unsubscribe(self, channel):
        with self.cond:
            left = self.clients.get(channel, 0) - 1
            if left > 0:
                self.clients[channel] = left
            else:
                self.clients.pop(channel, None)
            self.cond.notify_all()

    def wait(self, seen, timeout):
        """Topics published after sequence number `seen`, waiting up to `timeout` seconds for one:
        (new seen, [(name, seq, JSON text)])."""
        with self.cond:
            self.cond.wait_for(lambda: self.seq > seen, max(0.0, timeout))
            items = sorted(((name, seq, text) for name, (seq, _key, text) in self.latest.items() if seq > seen),
                           key=lambda item: item[1])
            return self.seq, items

    def nudge(self, name):
        """A watcher saw a change: the topic is read on the next tick."""
        with self.cond:
            self.due[name] = 0.0

    def watch(self, on):
        for watcher in self.watchers:
            try:
                watcher.start() if on else watcher.stop()
            except Exception as err:  # a watcher's failure leaves the topics running
                self.log("izleyici %s (%s)" % ("başlatılamadı" if on else "durdurulamadı", err.__class__.__name__))

    # -- producer
    def run(self):
        while True:
            with self.cond:
                if not self.clients:
                    self.running = False
                    self.latest = {}
                    self.watch(False)
                    return
            self.step()
            with self.cond:
                self.cond.wait_for(lambda: not self.clients, self.tick)

    def step(self):
        """One pass: reads every topic that is due (slow ones in their own thread)."""
        now = self.clock()
        for topic in self.topics:
            if now < self.due.get(topic.name, 0.0):
                continue
            self.due[topic.name] = now + topic.every
            if not topic.slow:
                self.read(topic)
                continue
            with self.cond:
                if topic.name in self.busy:
                    continue
                self.busy.add(topic.name)
            threading.Thread(target=self.read, args=(topic,), name="konsol-olay-" + topic.name, daemon=True).start()

    def read(self, topic):
        try:
            value = topic.read()
            if value is None:
                return
            text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            key = topic.key(value) if topic.key else text
        except Exception as err:  # one topic's failure leaves the others running
            if topic.name not in self.failed:
                self.failed.add(topic.name)
                self.log("canlı olay okunamadı: %s (%s)" % (topic.name, err.__class__.__name__))
            return
        finally:
            with self.cond:
                self.busy.discard(topic.name)
        self.failed.discard(topic.name)
        self.publish(topic.name, key, text)

    def publish(self, name, key, text):
        with self.cond:
            old = self.latest.get(name)
            if old is not None and old[1] == key:
                return False
            self.seq += 1
            self.latest[name] = (self.seq, key, text)
            self.cond.notify_all()
            return True


def without(*fields):
    """A comparison key that ignores fields which change on every read (e.g. read_at)."""
    def key(value):
        return json.dumps({k: v for k, v in value.items() if k not in fields}, ensure_ascii=False, sort_keys=True)
    return key


def frame(name, seq, text):
    """One Server-Sent Events message; the JSON text has no newlines."""
    return "event: %s\nid: %d\ndata: %s\n\n" % (name, seq, text)
