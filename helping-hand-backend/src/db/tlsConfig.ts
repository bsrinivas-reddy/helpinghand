import {X509Certificate}from'node:crypto';
// Configuration builder only: never opens a database connection.
export const databaseConfig=(env:NodeJS.ProcessEnv)=>{
    const production=env.NODE_ENV==='production';const raw=env.DATABASE_URL;
    if(!raw&&production)throw new Error('DATABASE_URL required in production');
    let host='localhost';
    if(raw){let parsed:URL;try{parsed=new URL(raw);}catch{throw new Error('Invalid DATABASE_URL');}
        if(!['postgres:','postgresql:'].includes(parsed.protocol))throw new Error('PostgreSQL URL required');host=parsed.hostname;
        for(const key of parsed.searchParams.keys())if(['sslmode','sslcert','sslkey','sslrootcert','ssl','uselibpqcompat'].includes(key.toLowerCase()))throw new Error('Remove SSL URL overrides; use verified database TLS configuration');
    }
    const local=['localhost','127.0.0.1','[::1]','::1'].includes(host);
    const ca=env.DATABASE_CA_CERT;
    if(ca){try{new X509Certificate(ca);}catch{throw new Error('Invalid DATABASE_CA_CERT PEM');}}
    return {connectionString:raw,max:20,idleTimeoutMillis:30000,connectionTimeoutMillis:5000,
        ssl:production||!local||ca?{rejectUnauthorized:true,...(ca?{ca}:{})}:false};
};
