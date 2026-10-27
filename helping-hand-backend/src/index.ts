import {sendPublicError,reportInternal} from './utils/publicError.js';
import {startVerificationRecovery} from './services/callScheduler.js';
import 'dotenv/config';
import express, { Request, Response, NextFunction } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import pool from './db/db.js';
import redisClient from './db/redisClient.js';

import authRoutes from './modules/shared/auth.routes.js';
import workerRoutes from './modules/worker/worker.routes.js';
import employerRoutes from './modules/employer/employer.routes.js';
import { runMigrations } from './db/migrate.js';
import { corsOrigin, trustProxyHops } from './config/runtime.js';

const app = express();
const port = process.env.PORT || 3000;

// Rate limits key on req.ip, so the proxy depth must be explicit (see TRUST_PROXY).
app.set('trust proxy', trustProxyHops());

// Security HTTP Headers
app.use(helmet());

// CORS Configuration
app.use(cors({
    origin: corsOrigin(), // allowlist from CORS_ORIGINS
    methods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-User-Id']
}));

app.use(express.json({ limit: '1mb' }));

// Global Rate Limiter: 120 requests per minute per IP
const globalLimiter = rateLimit({
    windowMs: 60 * 1000,
    max: 120,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many requests from this IP, please try again later.' }
});
app.use(globalLimiter);

// Strict Rate Limiter for Authentication: 20 requests per 15 minutes per IP
const authLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 20,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many authentication attempts, please try again in 15 minutes.' }
});

// Health check endpoint
app.get('/health', async (_req: Request, res: Response) => {
    try {
        const dbResult = await pool.query('SELECT NOW()');
        const ping = await redisClient.ping();
        res.status(200).json({
            status: 'healthy',
            service: 'Helping Hand Core API',
            environment: process.env.NODE_ENV || 'unset',
            timestamp: dbResult.rows[0].now,
            redis: ping === 'PONG' ? 'connected' : 'error'
        });
    } catch (error: any) {
        sendPublicError(res,error,'health');
    }
});

// Mount Routes
app.use('/api/auth', authLimiter, authRoutes);
app.use('/api/worker', workerRoutes);
app.use('/api/employer', employerRoutes);

// 404 Route Handler
app.use((req: Request, res: Response) => {
    res.status(404).json({ success: false, error: `Route not found: ${req.method} ${req.url}` });
});

// Global Error Handler
app.use((err: any, _req: Request, res: Response, _next: NextFunction) => {
    sendPublicError(res,err,'unhandled');
});

let stopRecovery: (()=>Promise<void>) | undefined;
// Migrate first, then bind the port. A load balancer must never see an open port on a
// half-migrated schema, and a failed migration must stop the process before it serves.
await runMigrations().catch(err => {
    console.error('Startup aborted: migration failed:', err?.message ?? err);
    reportInternal('startup-migration');
    process.exitCode = 1;
    throw err;
});
const server = app.listen(port, () => {
    console.log(`🚀 Helping Hand Core API running on http://localhost:${port} in [${process.env.NODE_ENV || 'unset'}] mode`);
    stopRecovery = startVerificationRecovery();
});

// Graceful Shutdown on SIGTERM / SIGINT
const shutdown = async (signal: string) => {
    // Bound teardown even if cache/DB adapters stall. Process exit abandons no
    // detached worker; any claimed dispatch remains UNKNOWN/manual on recovery.
    const deadline=setTimeout(()=>process.exit(1),45000);deadline.unref();
    await stopRecovery?.();
    console.log(`\n🛑 [Shutdown] Received ${signal}. Closing server gracefully...`);
    server.close(async () => {
        try {
            await pool.end();
            console.log('📦 PostgreSQL connection pool drained.');
            if (redisClient.isOpen) {
                await redisClient.disconnect();
                console.log('🔴 Redis client disconnected.');
            }
            console.log('👋 Process exiting cleanly.');
            process.exit(0);
        } catch (err) {
            reportInternal('shutdown');
            process.exit(1);
        }
    });
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

export default app;