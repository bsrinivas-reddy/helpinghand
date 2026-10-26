import {test,mock,beforeEach} from 'node:test';import assert from 'node:assert/strict';import net from 'node:net';import twilio from 'twilio';
mock.method(net.Socket.prototype,'connect',()=>{throw new Error('No sockets');});
process.env.TWILIO_AUTH_TOKEN='fixture-token';process.env.TWILIO_ACCOUNT_SID='AC'+'1'.repeat(32);process.env.TWILIO_CALLBACK_BASE_URL='https://fixture.invalid';
const calls:any[]=[];const cache=new Map<string,string>();let row:any;let sendCount=0;let sendMode='success';
const query=async(sql:string,args:any[]=[])=>{calls.push({sql,args});if(sql.includes('SELECT * FROM shifts'))return {rows:row?[{...row}]:[]};if(sql.includes('SKIP LOCKED'))return {rows:row?.verification_call_status==='SCHEDULED'?[{...row}]:[]};if(sql.includes("SET verification_call_status='DISPATCHING'")){row.verification_call_status='DISPATCHING';return {rows:[]};}if(sql.includes('SET worker_call_confirmed')){row.worker_call_confirmed=args[0];row.verification_call_status=args[1];}if(sql.includes('SET employer_call_confirmed')){row.employer_call_confirmed=args[0];row.verification_call_status=args[1];}return {rows:[]};};
mock.module(new URL('../db/db.js',import.meta.url).href,{defaultExport:{query,connect:async()=>({query,release:()=>{}})}});
mock.module(new URL('../db/redisClient.js',import.meta.url).href,{defaultExport:{get:async(k:string)=>cache.get(k)??null,set:async(k:string,v:string)=>{cache.set(k,v);},eval:async(_s:string,o:any)=>{const b=JSON.parse(cache.get(o.keys[0])??'{}');if(b.callSid&&b.callSid!==o.arguments[0])return 0;b.callSid=o.arguments[0];cache.set(o.keys[0],JSON.stringify(b));return 1;}}});
mock.module(new URL('../services/twilioService.js',import.meta.url).href,{namedExports:{makeTwilioIvrCall:async()=>{sendCount++;if(sendMode==='fail')throw new Error('rejected');if(sendMode==='simulation')return {success:true,simulated:true};return {success:true,sid:'CA'+'2'.repeat(32)};}}});
const ivr=await import('../services/ivrService.js');const middleware=await import('../middlewares/ivr.middleware.js');const scheduler=await import('../services/callScheduler.js');
beforeEach(()=>{calls.length=0;cache.clear();sendCount=0;sendMode='success';row={shift_id:'s',status:'COMPLETED',verification_call_status:'DISPATCHED',worker_call_confirmed:false,employer_call_confirmed:false,worker_phone:'9999999999',employer_phone:'8888888888',actual_cash_paid:500};});
test('two role replies retain both flags with row locking, no overwrite',async()=>{
    await ivr.processIvrKeypress('s','worker','1');await ivr.processIvrKeypress('s','employer','1');assert.equal(row.verification_call_status,'VERIFIED');assert.equal(row.worker_call_confirmed,true);assert.equal(row.employer_call_confirmed,true);assert.ok(calls.some(c=>c.sql.includes('FOR UPDATE')));
});
test('dispute never reversed by yes, duplicate yes no write',async()=>{
    await ivr.processIvrKeypress('s','worker','1');const count=calls.filter(c=>c.sql.startsWith('UPDATE')).length;
    await ivr.processIvrKeypress('s','worker','1');assert.equal(calls.filter(c=>c.sql.startsWith('UPDATE')).length,count);
    await ivr.processIvrKeypress('s','employer','2');await ivr.processIvrKeypress('s','worker','1');assert.equal(row.verification_call_status,'DISPUTED');
});
test('callbacks cannot confirm non-completed or unscheduled ledger',async()=>{row.status='ACTIVE';await assert.rejects(ivr.processIvrKeypress('s','worker','1'));row.status='COMPLETED';row.verification_call_status='SCHEDULED';await assert.rejects(ivr.processIvrKeypress('s','worker','1'));});
test('dispatch rejection/simulation never reports actual success',async()=>{for(const mode of ['fail','simulation']){sendMode=mode;const result=await ivr.dispatchIvrCalls({shiftId:'s',workerPhone:'9999999999',employerPhone:'8888888888',agreedWage:500});assert.equal(result.success,false);assert.equal(result.status,'UNKNOWN');}});
test('recovery claims only persisted scheduled rows, no unknown replay',async()=>{row.verification_call_status='SCHEDULED';await scheduler.recoverDueVerification();assert.equal(sendCount,2);assert.ok(calls.some(c=>c.sql.includes('SKIP LOCKED')));row.verification_call_status='UNKNOWN';await scheduler.recoverDueVerification();assert.equal(sendCount,2);});
function response(){const r:any={code:200,locals:{},status(n:number){r.code=n;return r;},json(_d:any){return r;}};return r;}
function callback(body:any,nonce:string,signature?:string){const originalUrl=`/api/worker/shifts/s/ivr-callback?dispatch=${nonce}`;return {body,params:{shiftId:'s'},query:{dispatch:nonce},originalUrl,is:(type:string)=>type==='application/x-www-form-urlencoded',get:()=>signature??twilio.getExpectedTwilioSignature(process.env.TWILIO_AUTH_TOKEN!,`https://fixture.invalid${originalUrl}`,body)} as any;}
test('official signature valid+full unknown form params+bound role accepted',async()=>{const nonce='a'.repeat(64);const body={AccountSid:process.env.TWILIO_ACCOUNT_SID,CallSid:'CA'+'2'.repeat(32),Digits:'1',To:'+919999999999',NewProviderField:'preserved'};cache.set(middleware.dispatchBindingKey(nonce),JSON.stringify({shiftId:'s',role:'worker',to:body.To}));const req=callback(body,nonce);const res=response();let accepted=false;await middleware.validateIvrCallback('worker')(req,res,()=>{accepted=true;});assert.equal(accepted,true);assert.equal(res.locals.ivrRole,'worker');});
test('bad signature/config/binding rejected before next',async()=>{const nonce='b'.repeat(64);const body={AccountSid:process.env.TWILIO_ACCOUNT_SID,CallSid:'CA'+'2'.repeat(32),Digits:'1',To:'+919999999999'};const req=callback(body,nonce,'bad');const res=response();let next=false;await middleware.validateIvrCallback('worker')(req,res,()=>{next=true;});assert.equal(res.code,403);assert.equal(next,false);const good=callback(body,nonce);await middleware.validateIvrCallback('worker')(good,res,()=>{next=true;});assert.equal(next,false);});

test('signed wrong party, SID, URL or malformed content cannot advance callback',async()=>{
    const nonce='c'.repeat(64),base={AccountSid:process.env.TWILIO_ACCOUNT_SID,CallSid:'CA'+'2'.repeat(32),Digits:'1',To:'+919999999999'};
    cache.set(middleware.dispatchBindingKey(nonce),JSON.stringify({shiftId:'s',role:'worker',to:base.To,callSid:base.CallSid}));
    for(const body of [{...base,To:'+918888888888'},{...base,CallSid:'CA'+'3'.repeat(32)},{...base,AccountSid:'AC'+'3'.repeat(32)}]){const res=response();let next=false;await middleware.validateIvrCallback('worker')(callback(body,nonce),res,()=>{next=true;});assert.equal(next,false);assert.equal(res.code,403);}
    const req=callback(base,nonce);req.originalUrl+='&changed=1';req.get=()=>twilio.getExpectedTwilioSignature(process.env.TWILIO_AUTH_TOKEN!,`https://fixture.invalid/api/worker/shifts/s/ivr-callback?dispatch=${nonce}`,base);const res=response();let next=false;await middleware.validateIvrCallback('worker')(req,res,()=>{next=true;});assert.equal(next,false);assert.equal(res.code,403);
});

test('configurable operational defaults are bounded and provider timeout remains below stale threshold',async()=>{
    const {verificationConfig}=await import('../utils/verificationConfig.js');const config=verificationConfig();assert.equal(config.pollMs,60000);assert.equal(config.batch,20);assert.equal(config.bindingSeconds,86400);assert.equal(config.staleSeconds,900);assert.ok(config.providerTimeoutMs<config.staleSeconds*1000);
    process.env.VERIFICATION_PROVIDER_TIMEOUT_MS='999999';assert.throws(verificationConfig);delete process.env.VERIFICATION_PROVIDER_TIMEOUT_MS;
});
test('recovery loop fake timers: stop clears poll and waits current work, no real timer',async()=>{
    let tick:(()=>void)|undefined;let cleared=false;
    const timer={unref:()=>{}};
    const interval=mock.method(globalThis,'setInterval',((fn:()=>void)=>{tick=fn;return timer;})as any);
    const clear=mock.method(globalThis,'clearInterval',((_id:any)=>{cleared=true;})as any);
    try{row.verification_call_status='UNKNOWN';const stop=scheduler.startVerificationRecovery();assert.ok(tick);await stop();assert.equal(cleared,true);const count=sendCount;tick!();await Promise.resolve();assert.equal(sendCount,count);}finally{interval.mock.restore();clear.mock.restore();}
});

test('dispatch persists provider SID binding; callback after retention missing fails closed',async()=>{
    await ivr.dispatchIvrCalls({shiftId:'s',workerPhone:'9999999999',employerPhone:'8888888888',agreedWage:500});
    assert.equal(cache.size,2);assert.ok([...cache.values()].every(v=>JSON.parse(v).callSid==='CA'+'2'.repeat(32)));
    cache.clear();const nonce='d'.repeat(64);const body={AccountSid:process.env.TWILIO_ACCOUNT_SID,CallSid:'CA'+'2'.repeat(32),Digits:'1',To:'+919999999999'};const res=response();let next=false;await middleware.validateIvrCallback('worker')(callback(body,nonce),res,()=>{next=true;});assert.equal(res.code,403);assert.equal(next,false);
});
