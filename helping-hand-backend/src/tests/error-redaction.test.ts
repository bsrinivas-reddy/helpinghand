import {test,mock}from'node:test';import assert from'node:assert/strict';import net from'node:net';
mock.method(net.Socket.prototype,'connect',()=>{throw new Error('No sockets');});
process.env.NODE_ENV='production';process.env.JWT_SECRET='safe-fixture-production-access';process.env.JWT_REFRESH_SECRET='safe-fixture-production-refresh';
const sentinel='PRIVATE_SENTINEL_credential_sql_provider_body';let failSms=false;let failDb=false;const cache=new Map<string,string>();let sentOtp='';
mock.module(new URL('../db/db.js',import.meta.url).href,{defaultExport:{query:async()=>{if(failDb)throw new Error(sentinel);return {rows:[]};}}});
mock.module(new URL('../db/redisClient.js',import.meta.url).href,{defaultExport:{get:async(k:string)=>cache.get(k)??null,set:async(k:string,v:string)=>{cache.set(k,v);},incr:async()=>1,expire:async()=>1,del:async(k:string)=>cache.delete(k)}});
mock.module(new URL('../services/twilioService.js',import.meta.url).href,{namedExports:{sendTwilioSms:async(p:any)=>{sentOtp=p.body.match(/\d{6}/)?.[0]??'';if(failSms)throw new Error(sentinel);return {success:true};},makeTwilioIvrCall:()=>{throw new Error('Unexpected provider');}}});
mock.module(new URL('../services/googleAuth.service.js',import.meta.url).href,{namedExports:{verifyGoogleIdToken:()=>{throw new Error(sentinel);},getGoogleAuthUrl:()=>'',exchangeCodeForProfile:()=>{throw new Error(sentinel);}}});
const auth=await import('../modules/shared/auth.controller.js');const employer=await import('../modules/employer/employer.controller.js');const errors=await import('../utils/publicError.js');const {FlowError}=await import('../services/shiftState.service.js');
function response(){const r:any={code:200,data:null,status(n:number){r.code=n;return r;},json(d:any){r.data=d;return r;}};return r;}
const capture=async(work:()=>Promise<void>)=>{const entries:any[]=[];const logs=['log','error','warn'].map(key=>mock.method(console,key as 'log',(...args:any[])=>{entries.push(args);}));try{await work();}finally{logs.forEach(m=>m.mock.restore());}return JSON.stringify(entries);};
test('production OTP success response/logs never expose OTP or full phone',async()=>{cache.clear();failSms=false;const res=response();const logs=await capture(()=>auth.sendOtp({body:{phoneNumber:'9999999999',role:'worker'}}as any,res));assert.equal(res.code,200);assert.ok(sentOtp);assert.equal(res.data.otp,undefined);assert.ok(!logs.includes(sentOtp));assert.ok(!logs.includes('9999999999'));});
test('production SMS failure sentinel and secrets absent from response and logs',async()=>{cache.clear();failSms=true;const res=response();const logs=await capture(()=>auth.sendOtp({body:{phoneNumber:'9999999999',role:'worker'}}as any,res));assert.equal(res.code,500);assert.equal(res.data.code,'INTERNAL_ERROR');assert.match(res.data.requestId,/^[a-f0-9-]{36}$/);assert.ok(!JSON.stringify(res.data).includes(sentinel));assert.ok(!logs.includes(sentinel));assert.ok(!logs.includes(sentOtp));assert.ok(!logs.includes('9999999999'));});
test('database unexpected errors are generic with correlation, domain409 stays useful',async()=>{failDb=true;const res=response();const logs=await capture(()=>employer.getEmployerShifts({params:{userId:'e'},user:{userId:'e',role:'employer'}}as any,res));assert.equal(res.code,500);assert.equal(res.data.code,'INTERNAL_ERROR');assert.ok(!logs.includes(sentinel));assert.ok(!JSON.stringify(res.data).includes(sentinel));const domain=response();errors.sendPublicError(domain,new FlowError(409,'handshake_required'),'fixture');assert.equal(domain.code,409);assert.equal(domain.data.error,'handshake_required');});

test('production pg/redis/provider-shaped secret objects never enter public error or diagnostics',async()=>{
    for(const error of [Object.assign(new Error(sentinel),{detail:sentinel,query:sentinel}),{message:sentinel,body:{token:sentinel},stack:sentinel},sentinel]){
        const res=response();const logs=await capture(async()=>errors.sendPublicError(res,error,'fixture-category'));
        assert.equal(res.code,500);assert.ok(!logs.includes(sentinel));assert.ok(!JSON.stringify(res.data).includes(sentinel));assert.ok(logs.includes(res.data.requestId));
    }
});
