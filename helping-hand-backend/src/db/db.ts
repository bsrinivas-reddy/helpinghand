import {databaseConfig} from './tlsConfig.js';
import pg from 'pg';
import 'dotenv/config';

const { Pool } = pg;
const pool = new Pool(databaseConfig(process.env));

pool.on('error', (err: Error) => {
    console.error('⚠️ [Database Error] Unexpected error on idle client:');
});

pool.on('connect', () => {
    // Client connected successfully
});

export default pool;