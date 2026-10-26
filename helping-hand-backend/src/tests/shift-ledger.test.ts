import {test,mock,beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
mock.method(net.Socket.prototype,'connect',()=>{throw new Error('No sockets');});
const calls:{sql:string;args:any[]}[]=[];
let shift:any, available:boolean, conflict:boolean;
const query=async(sql:string,args:any[]=[])=>{
    calls.push({sql,args});
    if(sql.includes('SELECT worker_id, is_available'))return {rows:[{worker_id:'w',is_available:available}]};
    if(sql.includes('SELECT worker_id FROM workers'))return {rows:[{worker_id:'w'}]};
    if(sql.includes('SELECT * FROM shifts'))return {rows:shift&&shift.worker_id===args[1]?[{...shift}]:[]};
    if(sql.includes('SELECT shift_id FROM shifts'))return {rows:conflict?[{shift_id:'busy'}]:[]};
    if(sql.includes('SELECT employer_id'))return {rows:[{employer_id:'e'}]};
    if(sql.includes('INSERT INTO shifts'))return {rows:[{employer_id:args[0],worker_id:args[1],agreed_daily_wage:args[2],platform_fee_paid:false}]};
    if(sql.startsWith('UPDATE shifts')){if(shift.status!==args[3])return {rows:[]};shift.status=args[0];return {rows:[{...shift}]};}
    return {rows:[]};
};
mock.module(new URL('../db/db.js',import.meta.url).href,{defaultExport:{connect:async()=>({query,release:()=>{}})}});
const state=await import('../services/shiftState.service.js');
beforeEach(()=>{calls.length=0;shift={shift_id:'s',worker_id:'w',status:'PENDING'};available=true;conflict=false;});
test('pending accept then active, atomic guarded updates and offline side effect',async()=>{
    assert.equal((await state.transitionWorkerShift('s','w','ACCEPTED')).status,'ACCEPTED');
    assert.equal((await state.transitionWorkerShift('s','w','ACTIVE')).status,'ACTIVE');
    assert.ok(calls.some(c=>c.sql.includes('FOR UPDATE')));assert.ok(calls.some(c=>c.sql.includes('status = $4')));
    assert.ok(calls.some(c=>c.sql.includes('UPDATE workers SET is_available = false')));
});
test('completed terminal cannot reverse to accepted or active',async()=>{
    shift.status='COMPLETED';for(const target of ['ACCEPTED','ACTIVE'] as const)await assert.rejects(state.transitionWorkerShift('s','w',target),(e:any)=>e.status===409);
    assert.equal(calls.filter(c=>c.sql.startsWith('UPDATE')).length,0);assert.ok(calls.some(c=>c.sql==='ROLLBACK'));
});
test('repeat resulting state is stable without repeating writes',async()=>{
    shift.status='ACCEPTED';await state.transitionWorkerShift('s','w','ACCEPTED');assert.equal(calls.filter(c=>c.sql.startsWith('UPDATE')).length,0);
});
test('skip pending directly active and foreign actor fail before writes',async()=>{
    await assert.rejects(state.transitionWorkerShift('s','w','ACTIVE'),(e:any)=>e.status===409);
    await assert.rejects(state.transitionWorkerShift('s','other','ACCEPTED'),(e:any)=>e.status===404);
    assert.equal(calls.filter(c=>c.sql.startsWith('UPDATE')).length,0);
});
test('worker busy cannot accept another request',async()=>{
    conflict=true;await assert.rejects(state.transitionWorkerShift('s','w','ACCEPTED'),(e:any)=>e.status===409);
});
test('targeted create feeFALSE and correct actor, no collected charge claim',async()=>{
    const result=await state.createTargetedShift('e','w',500);assert.equal(result.platform_fee_paid,false);
    assert.deepEqual(calls.find(c=>c.sql.includes('INSERT INTO'))!.args,['e','w',500]);
});
test('offline or busy/duplicate worker request fails without insertion',async()=>{
    available=false;await assert.rejects(state.createTargetedShift('e','w',500),(e:any)=>e.status===409);
    available=true;conflict=true;await assert.rejects(state.createTargetedShift('e','w',500),(e:any)=>e.status===409);
    assert.equal(calls.filter(c=>c.sql.includes('INSERT INTO')).length,0);
});

test('duplicate pending targeted request returns existing without insert even when worker now offline',async()=>{
    const original=query;
    // Replace fixture dispatch for this test only through the connection adapter.
    const dbModule=await import('../db/db.js');
    const existing={shift_id:'pending-original',status:'PENDING',worker_id:'w',employer_id:'e'};
    const originalConnect=dbModule.default.connect;
    (dbModule.default as any).connect=async()=>({query:async(sql:string,args:any[]=[])=>sql.includes("status='PENDING' ORDER BY")?{rows:[existing]}:original(sql,args),release:()=>{}});
    try{available=false;assert.equal((await state.createTargetedShift('e','w',500)).shift_id,'pending-original');assert.equal(calls.filter(c=>c.sql.includes('INSERT INTO')).length,0);}finally{(dbModule.default as any).connect=originalConnect;}
});
