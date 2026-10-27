import { OAuth2Client } from 'google-auth-library';
import { isDevShortcutEnv } from '../config/runtime.js';
import 'dotenv/config';

const clientId = process.env.GOOGLE_CLIENT_ID;
const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
const callbackUrl = process.env.GOOGLE_CALLBACK_URL || 'http://localhost:3000/api/auth/google/callback';

const oauth2Client = new OAuth2Client(clientId, clientSecret, callbackUrl);

export interface GoogleUserProfile {
    googleId: string;
    email: string;
    fullName?: string;
    avatarUrl?: string;
}

/**
 * Verify Google ID Token sent by Flutter mobile apps or web frontend.
 * In development/test mode, supports mock tokens formatted as 'mock-google-token:email:name:sub'
 */
export const verifyGoogleIdToken = async (idToken: string): Promise<GoogleUserProfile> => {
    // 1. Support test/mock tokens in non-production environments
    if (isDevShortcutEnv() && idToken.startsWith('mock-google-token:')) {
        const parts = idToken.split(':');
        return {
            email: parts[1] || 'mockuser@example.com',
            fullName: parts[2] || 'Mock Google User',
            googleId: parts[3] || 'mock-google-sub-99999',
            avatarUrl: 'https://lh3.googleusercontent.com/a/mock-avatar'
        };
    }

    if (!clientId) {
        throw new Error('GOOGLE_CLIENT_ID is not configured in server environment');
    }

    // 2. Cryptographically verify Google ID Token with Google's public certs
    const ticket = await oauth2Client.verifyIdToken({
        idToken,
        audience: clientId
    });

    const payload = ticket.getPayload();
    if (!payload || !payload.sub || !payload.email) {
        throw new Error('Invalid Google token payload: missing sub or email');
    }

    return {
        googleId: payload.sub,
        email: payload.email,
        fullName: payload.name,
        avatarUrl: payload.picture
    };
};

/**
 * Generate Google OAuth2 Web Consent Screen URL (for web clients)
 */
export const getGoogleAuthUrl = (state?: string): string => {
    if (!clientId) {
        throw new Error('GOOGLE_CLIENT_ID is not configured in server environment');
    }

    return oauth2Client.generateAuthUrl({
        access_type: 'offline',
        prompt: 'consent',
        scope: ['openid', 'profile', 'email'],
        state
    });
};

/**
 * Exchange Authorization Code for Tokens and User Profile (for web redirect callback)
 */
export const exchangeCodeForProfile = async (code: string): Promise<GoogleUserProfile> => {
    const { tokens } = await oauth2Client.getToken(code);
    oauth2Client.setCredentials(tokens);

    if (tokens.id_token) {
        return verifyGoogleIdToken(tokens.id_token);
    }

    throw new Error('Google OAuth callback did not return an ID token');
};
