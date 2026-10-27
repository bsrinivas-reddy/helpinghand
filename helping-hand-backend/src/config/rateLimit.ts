import rateLimit, { MemoryStore, type Store, type Options, type ClientRateLimitInfo } from 'express-rate-limit';

type Where = 'shared' | 'local';
const SHARED_TIMEOUT_MS = 400;
const INIT_RETRY_MS = 2000;

const withTimeout = <T>(p: Promise<T>, ms: number): Promise<T> => new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('shared store timeout')), ms);
    p.then(v => { clearTimeout(t); resolve(v); }, e => { clearTimeout(t); reject(e); });
});

// Counts hits in a shared store (Redis) so limits hold across instances and restarts.
//
// When the shared store fails or stalls (a node-redis client queues commands while offline
// instead of rejecting, so every call is bounded by a timeout):
//   - mode 'local': the hit is counted in this process's memory. The limit stays enforced and
//     routes that do not need Redis stay up. While the store is down the limit is per instance
//     (N instances allow up to N times the limit, and a restart clears the local counts).
//   - mode 'reject': the error is returned to the caller, so the request fails (a closed
//     limiter). Use it where a weaker limit would be unsafe.
// Decrement is best-effort after a store switch: one entry per key records the store of the
// latest hit. (express-rate-limit only calls it for skipped requests, which are not configured.)
// A key that started counting locally keeps counting locally until its window ends, so the store
// coming back cannot give it a second budget. A key that started in the shared store still gets
// a fresh local budget when an outage begins (its shared count is unreachable): that is the N x
// tradeoff above.
export class FallbackStore implements Store {
    localKeys = false;
    prefix?: string;
    private options?: Options;
    private ready = false;
    private lastInit = 0;
    private readonly local = new MemoryStore();
    private readonly counted = new Map<string, { where: Where; until: number }>();
    private readonly pendingResets = new Map<string, number>(); // key -> window end
    constructor(
        private readonly shared: Store,
        private readonly mode: 'local' | 'reject' = 'local',
        private readonly onState: (event: 'fallback' | 'recovered') => void = () => {},
        private readonly timeoutMs = SHARED_TIMEOUT_MS,
    ) {}

    init(options: Options): void {
        this.options = options;
        this.local.init(options);
        void this.ensureShared();
    }
    private async ensureShared(): Promise<boolean> {
        if (this.ready) {
            // A replay that failed part-way is retried on later hits until nothing is pending.
            if (this.pendingResets.size > 0) await this.replayResets();
            return true;
        }
        const now = Date.now();
        if (this.lastInit && now - this.lastInit < INIT_RETRY_MS) return false;
        this.lastInit = now;
        try {
            await withTimeout(Promise.resolve(this.shared.init?.(this.options as Options)), this.timeoutMs);
            this.ready = true;
            this.lastInit = 0;
            await this.replayResets();
            this.onState('recovered');
        } catch {
            this.ready = false;
            this.onState('fallback');
        }
        return this.ready;
    }
    // A reset that could not reach the shared store is replayed once it is back, so the old
    // shared count cannot reappear after recovery.
    private async replayResets(): Promise<void> {
        const now = Date.now();
        for (const [key, until] of [...this.pendingResets]) {
            if (until <= now) { this.pendingResets.delete(key); continue; } // its count has expired anyway
            try {
                await withTimeout(Promise.resolve(this.shared.resetKey(key)), this.timeoutMs);
                this.pendingResets.delete(key);
            } catch { return; }
        }
    }
    private sharedFailed(): void {
        this.ready = false;
        this.onState('fallback');
    }
    private remember(key: string, where: Where, resetTime?: Date): void {
        const now = Date.now();
        if (this.counted.size >= 10000) {
            for (const [k, v] of this.counted) if (v.until <= now) this.counted.delete(k);
            // Still full of live windows: drop the oldest entries rather than grow without bound.
            while (this.counted.size >= 50000) this.counted.delete(this.counted.keys().next().value as string);
        }
        // Use the window end the store reported for this hit, not now + windowMs.
        const until = resetTime ? resetTime.getTime() : now + (this.options?.windowMs ?? 60000);
        this.counted.set(key, { where, until });
    }
    private heldLocally(key: string): boolean {
        const e = this.counted.get(key);
        return !!e && e.where === 'local' && e.until > Date.now();
    }
    async increment(key: string): Promise<ClientRateLimitInfo> {
        const held = this.heldLocally(key);
        if (!held && await this.ensureShared()) {
            try {
                const r = await withTimeout(Promise.resolve(this.shared.increment(key)), this.timeoutMs);
                this.remember(key, 'shared', r.resetTime);
                return r;
            } catch (err) {
                this.sharedFailed();
                if (this.mode === 'reject') throw err;
            }
        } else if (!held && this.mode === 'reject') {
            this.sharedFailed();
            throw new Error('rate limit store unavailable');
        }
        const r = await this.local.increment(key);
        this.remember(key, 'local', r.resetTime);
        return r;
    }
    async decrement(key: string): Promise<void> {
        // Undo the hit in the store that counted it, and only inside its window.
        const entry = this.counted.get(key);
        if (!entry || entry.until <= Date.now()) return;
        if (entry.where === 'shared') {
            try { await withTimeout(Promise.resolve(this.shared.decrement(key)), this.timeoutMs); } catch { this.sharedFailed(); }
        } else {
            await this.local.decrement(key);
        }
    }
    async resetKey(key: string): Promise<void> {
        try {
            await withTimeout(Promise.resolve(this.shared.resetKey(key)), this.timeoutMs);
            this.pendingResets.delete(key);
        } catch {
            if (this.pendingResets.size >= 10000) this.pendingResets.delete(this.pendingResets.keys().next().value as string);
            this.pendingResets.set(key, Date.now() + (this.options?.windowMs ?? 60000));
            this.sharedFailed();
        }
        await this.local.resetKey(key);
        this.counted.delete(key);
    }
}

export const buildLimiter = (
    opts: { windowMs: number; max: number; message: unknown; mode?: 'local' | 'reject' },
    shared: Store,
    onState?: (event: 'fallback' | 'recovered') => void
) => rateLimit({
    windowMs: opts.windowMs,
    limit: opts.max,
    standardHeaders: true,
    legacyHeaders: false,
    message: opts.message as any,
    store: new FallbackStore(shared, opts.mode ?? 'local', onState),
});
