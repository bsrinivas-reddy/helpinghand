type Env = Record<string, string | undefined>;

// Dev shortcuts (mock Google tokens, OTP echoed in the response) are allowed only when the
// environment is named explicitly. A missing or misspelt NODE_ENV must fail closed, not open.
export const isDevShortcutEnv = (env: Env = process.env): boolean =>
    env.NODE_ENV === 'development' || env.NODE_ENV === 'test';

// CORS_ORIGINS is a comma-separated allowlist. The mobile apps are not browsers and need no CORS,
// so with no list set, browsers get no cross-origin access outside dev/test.
export const corsOrigin = (env: Env = process.env): string | string[] | false => {
    const list = (env.CORS_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
    if (list.includes('*') && !isDevShortcutEnv(env)) {
        throw new Error('CORS_ORIGINS must list explicit origins outside development');
    }
    for (const o of list) {
        if (o === '*') continue;
        // An allowlist entry must be a bare origin. 'null', paths and trailing slashes never
        // match a real browser Origin header (or, for 'null', match the wrong thing).
        let ok = false;
        try {
            const u = new URL(o);
            ok = (u.protocol === 'https:' || u.protocol === 'http:') && u.origin === o && !o.includes('*');
        } catch { /* invalid */ }
        if (!ok) throw new Error(`CORS_ORIGINS entry is not a bare origin: ${o}`);
        if (!isDevShortcutEnv(env) && !o.startsWith('https://')) throw new Error(`CORS_ORIGINS entry must be https outside development: ${o}`);
    }
    if (list.length) return list;
    return isDevShortcutEnv(env) ? '*' : false;
};

// TRUST_PROXY is the number of reverse-proxy hops in front of the app. Unset means 0, so
// X-Forwarded-For is ignored and a client cannot pick its own rate-limit key.
export const trustProxyHops = (env: Env = process.env): number => {
    const raw = env.TRUST_PROXY;
    if (raw === undefined || raw === '') return 0;
    const n = /^\d{1,2}$/.test(raw) ? Number(raw) : NaN;
    if (!Number.isInteger(n) || n > 10) throw new Error('TRUST_PROXY must be an integer from 0 to 10');
    return n;
};
