import {test} from'node:test';import assert from'node:assert/strict';import express from'express';import type {AddressInfo} from'node:net';
import {buildLimiter,FallbackStore} from'../config/rateLimit.js';
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
// Fake "Redis": one counter map shared by every limiter instance that is given it. fail=throw, hang=never answers
// (what a node-redis client with an offline queue does while disconnected).
class FakeShared{hits=new Map<string,number>();fail=false;hang=false;initFails=false;
    private gate<T>(v:()=>T):Promise<T>{if(this.hang)return new Promise<T>(()=>{});if(this.fail)return Promise.reject(new Error('redis down'));return Promise.resolve(v());}
    init(){if(this.initFails)return Promise.reject(new Error('script load failed'));return this.gate(()=>undefined);}
    increment(k:string){return this.gate(()=>{const n=(this.hits.get(k)??0)+1;this.hits.set(k,n);return {totalHits:n,resetTime:new Date(Date.now()+60000)};});}
    decrement(k:string){return this.gate(()=>{this.hits.set(k,(this.hits.get(k)??0)-1);});}
    resetKey(k:string){return this.gate(()=>{this.hits.delete(k);});}
}
const start=async(shared:FakeShared,max=3,mode:'local'|'reject'='local',onState?:(e:string)=>void)=>{
    const app=express();app.use(buildLimiter({windowMs:60000,max,mode,message:{success:false,error:'limited'}},shared as any,onState as any));app.get('/',(_q,r)=>{r.json({ok:true});});
    app.use((_e:any,_q:any,r:any,_n:any)=>{r.status(500).json({success:false});});
    const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
    return {server,url:`http://127.0.0.1:${(server.address() as AddressInfo).port}/`};
};
const codes=async(url:string,n:number)=>{const out:number[]=[];for(let i=0;i<n;i++)out.push((await fetch(url)).status);return out;};
test('two instances share one count, so the limit holds across processes',async()=>{
    const shared=new FakeShared();const a=await start(shared);const b=await start(shared);
    try{assert.deepEqual(await codes(a.url,2),[200,200]);assert.deepEqual(await codes(b.url,3),[200,429,429]);}
    finally{a.server.close();b.server.close();}
});
test('shared store down: the local mode keeps the limit and reports the fallback',async()=>{
    const shared=new FakeShared();shared.fail=true;const ev:string[]=[];const a=await start(shared,3,'local',e=>ev.push(e));
    try{assert.deepEqual(await codes(a.url,5),[200,200,200,429,429]);assert.ok(ev.includes('fallback'));}finally{a.server.close();}
});
test('a shared store that never answers (offline queue) is cut off by the timeout and falls back, requests do not hang',async()=>{
    const shared=new FakeShared();const a=await start(shared,2);await sleep(20);shared.hang=true;
    try{const t=Date.now();assert.deepEqual(await codes(a.url,3),[200,200,429]);assert.ok(Date.now()-t<3000,'requests must not hang');}finally{a.server.close();}
});
test('reject mode never serves a request without the shared store: no weaker limit to exploit',async()=>{
    const shared=new FakeShared();shared.fail=true;const a=await start(shared,2,'reject');
    try{assert.deepEqual(await codes(a.url,4),[500,500,500,500]);shared.fail=false;await sleep(2100);assert.deepEqual(await codes(a.url,3),[200,200,429]);}finally{a.server.close();}
});
test('a flap does not give one client a second budget: a key counted locally stays local until its window ends',async()=>{
    const shared=new FakeShared();shared.fail=true;const a=await start(shared,2);
    try{assert.deepEqual(await codes(a.url,1),[200]);shared.fail=false;await sleep(2100);assert.deepEqual(await codes(a.url,3),[200,429,429]);assert.equal(shared.hits.size,0);}finally{a.server.close();}
});
test('a shared store that failed its script load is retried later and used once it recovers',async()=>{
    const shared=new FakeShared();shared.initFails=true;const a=await start(shared,2);
    try{assert.deepEqual(await codes(a.url,1),[200]);assert.equal(shared.hits.size,0);}finally{a.server.close();}
    shared.initFails=false;await sleep(2100);const b=await start(shared,2);
    try{assert.deepEqual(await codes(b.url,3),[200,200,429]);assert.ok(shared.hits.size>0);}finally{b.server.close();}
});
test('decrement undoes the hit only in the store that counted it',async()=>{
    const shared=new FakeShared();const s=new FallbackStore(shared as any);s.init({windowMs:60000} as any);await sleep(10);
    await s.increment('a');await s.increment('a');await s.decrement('a');assert.equal(shared.hits.get('a'),1);
    assert.equal(await (s as any).local.get('a'),undefined);
    shared.fail=true;await s.increment('b');await s.decrement('b');shared.fail=false;assert.equal(shared.hits.get('b'),undefined);
    assert.equal((await (s as any).local.get('b'))?.totalHits??0,0);
});
test('resetKey clears both stores',async()=>{
    const shared=new FakeShared();const s=new FallbackStore(shared as any);s.init({windowMs:60000} as any);await sleep(10);
    await s.increment('k');shared.fail=true;await s.resetKey('k');shared.fail=false;
    await s.resetKey('k');assert.equal(shared.hits.has('k'),false);assert.equal((await s.increment('k')).totalHits,1);
});
test('a reset that failed during an outage is replayed when the store returns, so the old count does not reappear',async()=>{
    const shared=new FakeShared();const s=new FallbackStore(shared as any);s.init({windowMs:60000} as any);await sleep(10);
    await s.increment('k');await s.increment('k');assert.equal(shared.hits.get('k'),2);
    shared.fail=true;await s.resetKey('k');assert.equal(shared.hits.get('k'),2);
    shared.fail=false;await sleep(2100);await s.increment('other');
    assert.equal(shared.hits.has('k'),false);
});
test('decrement after the counted window has ended is ignored, and expired entries are pruned',async()=>{
    const shared=new FakeShared();const s=new FallbackStore(shared as any);s.init({windowMs:50} as any);await sleep(10);
    await s.increment('a');(s as any).counted.get('a').until=Date.now()-1;await s.decrement('a');
    assert.equal(shared.hits.get('a'),1,'a late decrement must not touch a later window');
    for(let i=0;i<10001;i++)(s as any).counted.set('old'+i,{where:'shared',until:1});
    await s.increment('fresh');
    assert.ok((s as any).counted.size<100,'expired entries are pruned');
});
test('a key counted locally returns to the shared store once its (short) window has ended',async()=>{
    const sh=new FakeShared();const s=new FallbackStore(sh as any);s.init({windowMs:300} as any);await sleep(10);
    sh.fail=true;await s.increment('k');sh.fail=false;await sleep(2100);// local window (300ms) is over
    await s.increment('k');assert.equal(sh.hits.get('k'),1,'next hit must land in the shared store');
});
test('a partially failed replay is retried on later hits until every pending reset has been applied',async()=>{
    const shared=new FakeShared();const s=new FallbackStore(shared as any);s.init({windowMs:60000} as any);await sleep(10);
    await s.increment('a');await s.increment('b');shared.fail=true;await s.resetKey('a');await s.resetKey('b');shared.fail=false;
    const orig=shared.resetKey.bind(shared);let calls=0;
    shared.resetKey=(k:string)=>{calls++;return calls===2?Promise.reject(new Error('flap')):orig(k);};
    await sleep(2100);await s.increment('x');// replays a, fails on b
    assert.equal(shared.hits.has('a'),false);assert.equal(shared.hits.has('b'),true);
    await s.increment('y');
    assert.equal(shared.hits.has('b'),false,'the remaining reset must be retried on a later hit');
});
