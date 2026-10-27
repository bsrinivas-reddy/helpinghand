import jwt from 'jsonwebtoken';
import 'dotenv/config';
import { isDevShortcutEnv } from '../config/runtime.js';

const ACCESS_FALLBACK = 'helping_hand_dev_jwt_secret_change_me_in_prod';
const REFRESH_FALLBACK = 'helping_hand_dev_refresh_secret_change_me_in_prod';
const secret = (kind: 'access' | 'refresh'): string => {
    const configured = process.env[kind === 'access' ? 'JWT_SECRET' : 'JWT_REFRESH_SECRET'];
    // Only an explicitly named dev/test environment may fall back to the built-in secrets.
    if (!isDevShortcutEnv()) {
        const access = process.env.JWT_SECRET?.trim();
        const refresh = process.env.JWT_REFRESH_SECRET?.trim();
        if (!access || !refresh || [ACCESS_FALLBACK, REFRESH_FALLBACK].includes(access) ||
            [ACCESS_FALLBACK, REFRESH_FALLBACK].includes(refresh) || access === refresh) {
            throw new Error('Production requires distinct configured access and refresh JWT secrets');
        }
    }
    return configured || (kind === 'access' ? ACCESS_FALLBACK : REFRESH_FALLBACK);
};
// Import-time gate prevents startup with unsafe production secrets. Runtime checks
// also guard each signing/verification operation.
secret('access');
const JWT_EXPIRES_IN = (process.env.JWT_EXPIRES_IN || '1d') as any;
const JWT_REFRESH_EXPIRES_IN = (process.env.JWT_REFRESH_EXPIRES_IN || '7d') as any;

export interface TokenPayload {
    userId: string;
    role: 'employer' | 'worker';
    phoneNumber?: string;
    email?: string;
}

export const signAccessToken = (payload: TokenPayload): string => {
    return jwt.sign({...payload, tokenUse: 'access'}, secret('access'), { expiresIn: JWT_EXPIRES_IN });
};

export const signRefreshToken = (payload: TokenPayload): string => {
    return jwt.sign({...payload, tokenUse: 'refresh'}, secret('refresh'), { expiresIn: JWT_REFRESH_EXPIRES_IN });
};

export const verifyAccessToken = (token: string): TokenPayload => {
    return validatePayload(jwt.verify(token, secret('access')), 'access');
};

export const verifyRefreshToken = (token: string): { userId: string; role: 'employer' | 'worker' } => {
    return validatePayload(jwt.verify(token, secret('refresh')), 'refresh');
};

const validatePayload = (payload: unknown, use: string): TokenPayload => {
    if (!payload || typeof payload !== 'object' ||
        !('tokenUse' in payload) || payload.tokenUse !== use ||
        !('userId' in payload) || typeof payload.userId !== 'string' || !payload.userId.trim() ||
        !('role' in payload) || (payload.role !== 'worker' && payload.role !== 'employer')) {
        throw new Error('Invalid session token payload');
    }
    return payload as TokenPayload;
};
