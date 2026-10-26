import crypto from 'crypto';
import redis from '../db/redisClient.js';
const key = (grant: string): string => `registration:${crypto.createHash('sha256').update(grant).digest('hex')}`;
export const issueRegistrationGrant = async (phoneNumber: string, role: 'worker' | 'employer'): Promise<string> => {
    const grant = crypto.randomBytes(32).toString('hex');
    await redis.set(key(grant), JSON.stringify({phoneNumber, role}), {EX:300});
    return grant;
};
export const consumeRegistrationGrant = async (grant: unknown, phoneNumber: string, role: string): Promise<boolean> => {
    if (typeof grant !== 'string' || !/^[a-f0-9]{64}$/.test(grant)) return false;
    const stored = await redis.getDel(key(grant));
    if (!stored) return false;
    try {
        const proof = JSON.parse(stored);
        return proof.phoneNumber === phoneNumber && proof.role === role;
    } catch { return false; }
};
