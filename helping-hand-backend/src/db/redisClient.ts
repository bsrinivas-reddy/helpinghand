import { createClient } from 'redis';
import 'dotenv/config';

const client = createClient({
    url: process.env.REDIS_URL || 'redis://localhost:6379'
});

client.on('error', (err) => {
    console.error('⚠️ [Redis Error]:');
});

client.on('connect', () => {
    console.log('✅ Connected to Redis');
});

client.on('reconnecting', () => {
    console.log('🔄 Reconnecting to Redis...');
});

(async () => {
    try {
        if (!client.isOpen) {
            await client.connect();
        }
    } catch (err: any) {
        console.error('❌ Failed initial connection to Redis:');
    }
})();

export default client;