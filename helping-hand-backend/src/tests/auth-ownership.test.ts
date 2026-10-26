import { test, mock, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { Request, Response } from 'express';

// Replace adapters before loading any application module. No entrypoint is imported.
mock.method(net.Socket.prototype, 'connect', () => { throw new Error('Outbound sockets forbidden in isolated regressions'); });
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'fixture-access-secret-not-for-deployment';
process.env.JWT_REFRESH_SECRET = 'fixture-refresh-secret-not-for-deployment';
const calls: {sql: string; values: unknown[]}[] = [];
let queryResult: (sql: string, values: unknown[]) => any = () => ({ rows: [] });
const pool = { connect: async () => ({query: async (sql:string,values:unknown[]=[]) => {if(['BEGIN','COMMIT','ROLLBACK'].includes(sql))return {rows:[]}; calls.push({sql,values});return queryResult(sql,values);},release:()=>{}}), query: async (sql: string, values: unknown[] = []) => { calls.push({sql, values}); return queryResult(sql, values); } };
const cache = new Map<string, string>();
const expiration = new Map<string, number>();
let fixtureNow = 0;
const readCache = (key:string) => { if ((expiration.get(key) ?? Infinity) <= fixtureNow) {cache.delete(key);expiration.delete(key);} return cache.get(key) ?? null; };
const redis = {
    get: async (key: string) => readCache(key),
    getDel: async (key: string) => { const value = readCache(key); cache.delete(key); return value; },
    set: async (key: string, value: string, options?: {EX:number}) => { cache.set(key, value); if(options) expiration.set(key,fixtureNow+options.EX*1000); return 'OK'; },
    eval: async (_script:string, options:{keys:string[];arguments:string[]}) => { if(readCache(options.keys[0])!==options.arguments[0]) return 0; return Number(cache.delete(options.keys[0])); },
    del: async (key: string) => Number(cache.delete(key)),
    incr: async (key: string) => { const n = Number(cache.get(key) ?? 0) + 1; cache.set(key, String(n)); return n; },
    expire: async () => 1, geoAdd: async () => 1, zRem: async () => 1, geoSearch: async () => []
};
let fixtureSms: ((params:any)=>any) | undefined;
const sendSms = (params:any) => { if(!fixtureSms) throw new Error('Unexpected SMS adapter use'); return fixtureSms(params); };
const failProvider = () => { throw new Error('Provider use forbidden in isolated regressions'); };
mock.module(new URL('../db/db.js', import.meta.url).href, { defaultExport: pool });
mock.module(new URL('../db/redisClient.js', import.meta.url).href, { defaultExport: redis });
mock.module(new URL('../services/twilioService.js', import.meta.url).href, { namedExports: { sendTwilioSms: sendSms, makeTwilioIvrCall: failProvider } });
mock.module(new URL('../services/googleAuth.service.js', import.meta.url).href, { namedExports: { verifyGoogleIdToken: failProvider, getGoogleAuthUrl: failProvider, exchangeCodeForProfile: failProvider } });
mock.module(new URL('../services/callScheduler.js', import.meta.url).href, { namedExports: { scheduleAutomatedVerificationCall: async () => ({scheduled: true}) } });
mock.module(new URL('../services/ivrService.js', import.meta.url).href, { namedExports: { processIvrKeypress: failProvider } });
class FixtureFlowError extends Error {constructor(public status:number,message:string){super(message);}}
mock.module(new URL('../services/shiftState.service.js',import.meta.url).href,{namedExports:{transaction:async(work:any)=>work(pool),FlowError:FixtureFlowError, transitionWorkerShift:async(shiftId:string,actor:string,target:string)=>{const found=await pool.query('SELECT * FROM shifts WHERE shift_id = $1 AND worker_id = $2',[shiftId,actor]);if(!found.rows.length){throw new FixtureFlowError(404,'Shift not found');}await pool.query("UPDATE shifts SET status = 'ACCEPTED' WHERE shift_id = $1 AND worker_id = $2",[shiftId,actor]);return found.rows[0];},createTargetedShift:async(actor:string,target:string,wage:number)=>{await pool.query('SELECT employer_id FROM employers WHERE employer_id = $1',[actor]);const result=await pool.query('INSERT INTO shifts (employer_id,worker_id,agreed_daily_wage) VALUES ($1,$2,$3)',[actor,target,wage]);return result.rows[0];}}});
mock.module(new URL('../services/cashHandshake.service.js',import.meta.url).href,{namedExports:{initiateCash:async(id:string,actor:string)=>{const r=await pool.query('SELECT * FROM shifts WHERE shift_id=$1 AND worker_id = $2',[id,actor]);if(!r.rows.length)throw new FixtureFlowError(404,'Shift not found');await redis.set('shift_handshake:'+id,JSON.stringify({workerId:actor}));return {success:true};},completeCash:async(id:string,actor:string)=>{const r=await pool.query('SELECT * FROM shifts WHERE shift_id=$1 AND employer_id = $2',[id,actor]);if(!r.rows.length)throw new FixtureFlowError(404,'Shift not found');await pool.query('UPDATE shifts WHERE employer_id = $3',[null,id,actor]);await redis.del('shift_handshake:'+id);return {success:true};}}});
const worker = await import('../modules/worker/worker.controller.js');
const employer = await import('../modules/employer/employer.controller.js');
const auth = await import('../modules/shared/auth.controller.js');
const middleware = await import('../middlewares/auth.middleware.js');
const jwt = await import('../utils/jwt.js');
const grant = await import('../utils/registrationGrant.js');

function req(body: any = {}, params: any = {}, user?: any): Request {
    return {body, params, user, headers: {}, baseUrl: '/api/worker'} as unknown as Request;
}
function response() {
    const value: any = {code:200, data:undefined};
    value.status = (code: number) => { value.code = code; return value; };
    value.json = (data: any) => { value.data = data; return value; };
    return value as Response & {code: number; data: any};
}
beforeEach(() => { calls.length = 0; cache.clear(); expiration.clear(); fixtureNow=0; fixtureSms=undefined; queryResult = () => ({rows: []}); });

test('missing token is denied even in non-production', () => {
    const res = response(); let next = false;
    middleware.authenticateToken(req({workerId:'foreign'}), res, () => {next = true;});
    assert.equal(res.code, 401); assert.equal(next, false);
});
test('public registration without verified grant cannot update existing worker or mint session', async () => {
    queryResult = () => ({ rows:[{worker_id:'victim', phone_number:'9999999999'}] });
    const res = response();
    await worker.registerWorker(req({phoneNumber:'9999999999', workerCategory:'PLUMBER'}), res);
    assert.equal(res.code, 401); assert.equal(calls.length, 0); assert.equal(res.data.token, undefined);
});
test('foreign worker cannot accept shift or change availability as a side effect', async () => {
    queryResult = () => ({rows: []});
    const res = response();
    await worker.acceptShift(req({}, {shiftId:'foreign'}, {userId:'actor', role:'worker'}), res);
    assert.equal(res.code,404);
    assert.ok(calls.every(c => !/^UPDATE shifts/i.test(c.sql.trim()) || (c.sql.includes('worker_id') && c.values.includes('actor'))));
});
test('foreign employer shift detail is ownership-scoped', async () => {
    const res = response();
    await employer.getShiftById(req({}, {shiftId:'foreign'}, {userId:'actor', role:'employer'}), res);
    assert.equal(res.code,404);
    assert.ok(calls[0].sql.includes('employer_id = $2'));
    assert.equal(calls[0].values[1], 'actor');
});
test('fixed developer OTP cannot authorize unknown phone', async () => {
    const res = response();
    await auth.verifyOtp(req({phoneNumber:'9999999999', otp:'123456', role:'worker'}), res);
    assert.equal(res.code,400); assert.equal(calls.length,0);
});
test('refresh token signed with distinct key is not an access token', () => {
    assert.throws(() => jwt.verifyAccessToken(jwt.signRefreshToken({userId:'actor', role:'worker'})));
});

const actors = {worker:{userId:'worker-owner',role:'worker'},employer:{userId:'employer-owner',role:'employer'}} as const;
for (const [role, module, names] of [
    ['worker', worker, ['acceptShift','startShift','reconcileCash','getShiftById','generateCashHandshakeCode','submitWorkerRating']],
    ['employer', employer, ['adjustShiftTiming','reconcileCash','getShiftById','confirmCashHandshake','submitEmployerRating']]
] as const) {
    for (const name of names) {
        test(`${role} ${name}: foreign resource404 without mutation or cache effect`, async () => {
            const res = response();
            await ((module as any)[name])(req({shiftId:'foreign',ratingStars:4}, {shiftId:'foreign'}, actors[role]),res);
            assert.equal(res.code,404);
            assert.equal(calls.length,1);
            assert.ok(calls[0].sql.includes(`${role}_id = $2`));
            assert.equal(calls[0].values[1],actors[role].userId);
            assert.equal(cache.size,0);
        });
        test(`${role} ${name}: no session401 and wrong role403 without query`,async () => {
            for(const [user,code] of [[undefined,401],[actors[role==='worker'?'employer':'worker'],403]] as const) {
                const res=response(); await ((module as any)[name])(req({}, {shiftId:'any'},user),res);
                assert.equal(res.code,code); assert.equal(calls.length,0);
            }
        });
    }
}
for(const name of ['getWorkerStatus','getWorkerMyProfile','getWorkerShifts'] as const) {
    test(`${name}: foreign profile/list path denied before availability sync`,async()=>{
        const res=response(); await worker[name](req({}, {workerId:'foreign',userId:'foreign'},actors.worker),res);
        assert.equal(res.code,403);assert.equal(calls.length,0);
    });
}
test('foreign employer list denied before query',async()=>{
    const res=response();await employer.getEmployerShifts(req({}, {userId:'foreign'},actors.employer),res);
    assert.equal(res.code,403);assert.equal(calls.length,0);
});
test('location spoof updates only session worker',async()=>{
    queryResult=()=>({rows:[{worker_id:'worker-owner',is_available:false}]});
    const res=response();await worker.updateLocation(req({workerId:'victim',lat:12,lng:75},{},actors.worker),res);
    assert.equal(res.code,200);assert.equal(calls[0].values[2],'worker-owner');
});
test('availability spoof updates only session worker',async()=>{
    queryResult=()=>({rows:[{worker_id:'worker-owner',is_available:false}]});
    const res=response();await worker.toggleAvailability(req({workerId:'victim',isAvailable:false},{},actors.worker),res);
    assert.equal(res.code,200);assert.equal(calls.find(c=>c.sql.includes('UPDATE workers'))!.values[3],'worker-owner');
});
test('create shift derives employer from session, keeps worker target',async()=>{
    queryResult=()=>({rows:[{employer_id:'employer-owner',worker_id:'target-worker'}]});
    const res=response();await employer.createShift(req({employerId:'victim',workerId:'target-worker',agreedDailyWage:500},{},actors.employer),res);
    assert.equal(res.code,201);const inserted=calls.find(c=>c.sql.includes('INSERT INTO shifts'))!;
    assert.deepEqual(inserted.values,['employer-owner','target-worker',500]);
});
for(const role of ['worker','employer'] as const) {
    test(`${role} rating ignores spoof reviewer and reviewee, uses shift counterpart`,async()=>{
        queryResult=(sql)=>({rows:sql.includes('FROM shifts WHERE shift_id')?[{worker_id:'worker-owner',employer_id:'employer-owner'}]:[{avg_rating:4,total_ratings:1,completed_count:1,rating_id:'r'}]});
        const res=response();const fn=role==='worker'?worker.submitWorkerRating:employer.submitEmployerRating;
        await fn(req({shiftId:'owned',reviewerId:'victim',revieweeId:'unrelated',reviewerRole:role,ratingStars:4},{},actors[role]),res);
        assert.equal(res.code,201);const insert=calls.find(c=>c.sql.includes('INSERT INTO ratings'))!;
        assert.deepEqual(insert.values.slice(0,4),['owned',actors[role].userId,actors[role==='worker'?'employer':'worker'].userId,role]);
    });
}
test('worker owned accept updates only its shift and returns success',async()=>{
    queryResult=(sql)=>({rows:sql.includes('COUNT(*)')?[{count:'1'}]:[{worker_id:'worker-owner',employer_id:'employer-owner'}]});
    const res=response();await worker.acceptShift(req({}, {shiftId:'owned'},actors.worker),res);
    assert.equal(res.code,200);const update=calls.find(c=>c.sql.includes('UPDATE shifts'))!;
    assert.ok(update.sql.includes('worker_id = $2'));assert.deepEqual(update.values,['owned','worker-owner']);
});
test('production requires both non-default distinct secrets',()=>{
    const previous={...process.env};
    try {
        process.env.NODE_ENV='production';delete process.env.JWT_SECRET;
        assert.throws(()=>jwt.signAccessToken(actors.worker));
        process.env.JWT_SECRET='production-access';delete process.env.JWT_REFRESH_SECRET;
        assert.throws(()=>jwt.signAccessToken(actors.worker));
        process.env.JWT_REFRESH_SECRET='helping_hand_dev_refresh_secret_change_me_in_prod';
        assert.throws(()=>jwt.signAccessToken(actors.worker));
        process.env.JWT_REFRESH_SECRET='production-access';assert.throws(()=>jwt.signAccessToken(actors.worker));
        process.env.JWT_REFRESH_SECRET='production-refresh';assert.equal(jwt.verifyAccessToken(jwt.signAccessToken(actors.worker)).userId,'worker-owner');
    } finally {process.env=previous;}
});

test('middleware invalid bearer token401, valid bearer passes, wrong role403',()=>{
    const invalid=req();invalid.headers.authorization='Bearer definitely-invalid';const denied=response();
    let next=false;middleware.authenticateToken(invalid,denied,()=>{next=true;});assert.equal(denied.code,401);assert.equal(next,false);
    const valid=req();valid.headers.authorization=`Bearer ${jwt.signAccessToken(actors.worker)}`;const res=response();
    middleware.authenticateToken(valid,res,()=>{next=true;});assert.equal(next,true);assert.equal(valid.user?.userId,'worker-owner');
    next=false;middleware.requireRole('employer')(valid,res,()=>{next=true;});assert.equal(res.code,403);assert.equal(next,false);
});
test('JWT payload must identify a supported role and nonempty actor',async()=>{
    const jsonwebtoken=(await import('jsonwebtoken')).default;
    for(const payload of [{userId:'',role:'worker'},{userId:'actor',role:'admin'},{role:'worker'}]) {
        const token=jsonwebtoken.sign(payload,process.env.JWT_SECRET!);assert.throws(()=>jwt.verifyAccessToken(token));
    }
    assert.throws(()=>jwt.verifyAccessToken(jsonwebtoken.sign(actors.worker,process.env.JWT_SECRET!,{expiresIn:-1})));
});
for(const [role,module] of [['worker',worker],['employer',employer]] as const) {
    test(`${role} owned shift detail returns owned resource`,async()=>{
        queryResult=()=>({rows:[{shift_id:'owned',worker_id:'worker-owner',employer_id:'employer-owner'}]});
        const res=response();await module.getShiftById(req({}, {shiftId:'owned'},actors[role]),res);
        assert.equal(res.code,200);assert.equal(res.data.shift.shift_id,'owned');
        for(const call of calls) {assert.ok(call.sql.includes(`${role}_id = $2`));assert.equal(call.values[1],actors[role].userId);}
    });
    test(`${role} owned list succeeds and queries actor`,async()=>{
        const res=response();const fn=role==='worker'?worker.getWorkerShifts:employer.getEmployerShifts;
        await fn(req({}, {userId:actors[role].userId},actors[role]),res);
        assert.equal(res.code,200);assert.equal(calls[0].values[0],actors[role].userId);
    });
}
test('owned worker start preserves existing transition behavior and owner predicate',async()=>{
    queryResult=(sql)=>({rows:sql.includes('COUNT(*)')?[{count:'1'}]:[{shift_id:'owned',worker_id:'worker-owner'}]});
    const res=response();await worker.startShift(req({}, {shiftId:'owned'},actors.worker),res);
    assert.equal(res.code,200);assert.ok(calls.find(c=>c.sql.includes('UPDATE shifts'))!.sql.includes('worker_id = $2'));
});
test('owned handshake creation binds cached code to owned shift',async()=>{
    queryResult=()=>({rows:[{shift_id:'owned',worker_id:'worker-owner',employer_id:'employer-owner'}]});
    const res=response();await worker.generateCashHandshakeCode(req({lat:12,lng:75},{shiftId:'owned'},actors.worker),res);
    assert.equal(res.code,200);assert.equal(JSON.parse(cache.get('shift_handshake:owned')!).workerId,'worker-owner');
});
test('owned timing update is scoped to employer, no fee/transition policy change',async()=>{
    queryResult=()=>({rows:[{shift_id:'owned',worker_id:'worker-owner',employer_id:'employer-owner',status:'ACTIVE',agreed_daily_wage:500}]});
    const res=response();await employer.adjustShiftTiming(req({workedHours:8},{shiftId:'owned'},actors.employer),res);
    assert.equal(res.code,200);const update=calls.find(c=>c.sql.includes('UPDATE shifts'))!;
    assert.ok(update.sql.includes('employer_id=$7'));assert.equal(update.values[6],'employer-owner');
});

test('socket blocker itself rejects attempted outbound use',()=>{
    const socket=new net.Socket();assert.throws(()=>socket.connect(443,'example.invalid'),/Outbound sockets forbidden/);
});
test('legacy reconciliation refuses one-sided completion',async()=>{
    queryResult=()=>({rows:[{worker_id:'worker-owner',employer_id:'employer-owner'}]});
    for(const role of ['worker','employer'] as const){const res=response();await (role==='worker'?worker.reconcileCash:employer.reconcileCash)(req({}, {shiftId:'owned'},actors[role]),res);assert.equal(res.code,409);assert.equal(res.data.error,'handshake_required');}
});
test('owned employer handshake confirmation is owner-scoped before cache access',async()=>{
    cache.set('shift_handshake:owned',JSON.stringify({code:'4321',workerLat:12,workerLng:75,workerId:'worker-owner'}));
    queryResult=()=>({rows:[{shift_id:'owned',worker_id:'worker-owner',employer_id:'employer-owner',status:'ACTIVE',agreed_daily_wage:500}]});
    const res=response();await employer.confirmCashHandshake(req({handshakeCode:'4321',employerLat:12,employerLng:75},{shiftId:'owned'},actors.employer),res);
    assert.equal(res.code,200);assert.equal(cache.has('shift_handshake:owned'),false);
    assert.ok(calls.find(c=>c.sql.includes('UPDATE shifts'))!.sql.includes('employer_id = $3'));
});

for(const role of ['worker','employer'] as const) {
    test(`${role} valid OTP issues hashed-cache300second role-bound grant and registration succeeds once`,async()=>{
        cache.set(`otp:${role}:9999999999`,'654321');
        const verified=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role}),verified);
        assert.equal(verified.code,200);assert.equal(verified.data.isNewUser,true);assert.equal(verified.data.expiresInSeconds,300);
        const proof=verified.data.registrationGrant;assert.match(proof,/^[a-f0-9]{64}$/);
        const storedKey=[...cache.keys()].find(k=>k.startsWith('registration:'))!;
        assert.ok(!storedKey.includes(proof));assert.equal(expiration.get(storedKey),300000);
        assert.deepEqual(JSON.parse(cache.get(storedKey)!),{phoneNumber:'9999999999',role});
        assert.equal(verified.data.token,undefined);
        queryResult=(sql)=>({rows:sql.includes('INSERT INTO')?[{[`${role}_id`]:actors[role].userId}]:[]});
        const fn=role==='worker'?worker.registerWorker:employer.registerEmployer;
        const body={phoneNumber:'9999999999',workerCategory:'PLUMBER',fullName:'Test Employer',registrationGrant:proof};
        const registered=response();await fn(req(body),registered);
        assert.equal(registered.code,201);assert.equal(jwt.verifyAccessToken(registered.data.token).role,role);
        assert.ok(calls.some(c=>c.sql.includes('INSERT INTO')&&!c.sql.includes('ON CONFLICT')));
        const replay=response();const previousCalls=calls.length;await fn(req(body),replay);
        assert.equal(replay.code,401);assert.equal(calls.length,previousCalls);
    });
    test(`${role} invalid/expired/mismatched grant cannot mutate or mint token`,async()=>{
        const fn=role==='worker'?worker.registerWorker:employer.registerEmployer;
        const otherRole=role==='worker'?'employer':'worker';
        for(const proof of ['bad',await grant.issueRegistrationGrant('8888888888',role),await grant.issueRegistrationGrant('9999999999',otherRole)]) {
            const res=response();await fn(req({phoneNumber:'9999999999',workerCategory:'PLUMBER',fullName:'Test Employer',registrationGrant:proof}),res);
            assert.equal(res.code,401);assert.equal(calls.length,0);assert.equal(res.data.token,undefined);
        }
        const proof=await grant.issueRegistrationGrant('9999999999',role);fixtureNow=300001;
        const expired=response();await fn(req({phoneNumber:'9999999999',workerCategory:'PLUMBER',fullName:'Test Employer',registrationGrant:proof}),expired);
        assert.equal(expired.code,401);assert.equal(calls.length,0);
    });
    test(`${role} existing-account registration cannot overwrite or issue token even with valid proof`,async()=>{
        const proof=await grant.issueRegistrationGrant('9999999999',role);queryResult=()=>({rows:[{exists:1}]});
        const fn=role==='worker'?worker.registerWorker:employer.registerEmployer;const res=response();
        await fn(req({phoneNumber:'9999999999',workerCategory:'PLUMBER',fullName:'Test Employer',registrationGrant:proof}),res);
        assert.equal(res.code,409);assert.equal(res.data.token,undefined);assert.ok(calls.every(c=>c.sql.startsWith('SELECT')));
    });
    test(`${role} returning OTP session is explicitly same-role, not cross-role`,async()=>{
        cache.set(`otp:${role}:9999999999`,'654321');queryResult=()=>({rows:[{[`${role}_id`]:actors[role].userId}]});
        const res=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role}),res);
        assert.equal(res.code,200);assert.equal(jwt.verifyAccessToken(res.data.token).role,role);assert.equal(res.data.registrationGrant,undefined);
        assert.ok(calls[0].sql.includes(`FROM ${role}s`));
        const replay=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role}),replay);assert.equal(replay.code,400);
    });
}
test('wrong OTP produces neither grant nor session nor database query',async()=>{
    cache.set('otp:worker:9999999999','654321');const res=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'111111',role:'worker'}),res);
    assert.equal(res.code,400);assert.equal(calls.length,0);assert.equal(res.data.token,undefined);assert.equal(res.data.registrationGrant,undefined);
});
test('missing/invalid role never silently chooses worker or switches role',async()=>{
    for(const role of [undefined,'admin']) {
        const res=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role}),res);
        assert.equal(res.code,400);assert.equal(calls.length,0);
    }
});
test('verified second role gets enrollment grant without session switch or profile linking',async()=>{
    cache.set('otp:worker:9999999999','654321');queryResult=sql=>({rows:sql.includes('FROM employers')?[{exists:1}]:[]});
    const res=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role:'worker'}),res);
    assert.equal(res.code,200);assert.equal(res.data.isNewUser,true);assert.equal(res.data.role,'worker');
    assert.equal(res.data.token,undefined);assert.ok(res.data.registrationGrant);
    assert.ok(calls.every(c=>!c.sql.includes('FROM employers')));
});
test('access and refresh purpose binding rejects ambiguous old JWT and swapped token',async()=>{
    const jsonwebtoken=(await import('jsonwebtoken')).default;
    const old=jsonwebtoken.sign(actors.worker,process.env.JWT_SECRET!);assert.throws(()=>jwt.verifyAccessToken(old));
    const wrongPurpose=jsonwebtoken.sign({...actors.worker,tokenUse:'refresh'},process.env.JWT_SECRET!);assert.throws(()=>jwt.verifyAccessToken(wrongPurpose));
    assert.throws(()=>jwt.verifyRefreshToken(jwt.signAccessToken(actors.worker)));
    assert.equal(jwt.verifyRefreshToken(jwt.signRefreshToken(actors.worker)).userId,'worker-owner');
});

test('schema preserves explicit role and registration grant and optional legacy actor fields',async()=>{
    const schemas=await import('../utils/validation.schemas.js');
    assert.equal((schemas.verifyOtpSchema.parse({phoneNumber:'9999999999',otp:'654321',role:'worker'}) as any).role,'worker');
    assert.throws(()=>schemas.verifyOtpSchema.parse({phoneNumber:'9999999999',otp:'654321'}));
    assert.equal((schemas.registerWorkerSchema.parse({phoneNumber:'9999999999',workerCategory:'PLUMBER',registrationGrant:'proof'}) as any).registrationGrant,'proof');
    assert.equal((schemas.registerEmployerSchema.parse({phoneNumber:'9999999999',fullName:'Fixture Employer',registrationGrant:'proof'}) as any).registrationGrant,'proof');
    assert.deepEqual(schemas.submitRatingSchema.parse({shiftId:'12345678-1234-4234-8234-123456789abc',ratingStars:4}),{shiftId:'12345678-1234-4234-8234-123456789abc',ratingStars:4});
});
test('production secret configuration is checked on fresh module load before JWT use',async()=>{
    const previous={...process.env};
    try {
        process.env.NODE_ENV='production';delete process.env.JWT_SECRET;delete process.env.JWT_REFRESH_SECRET;
        await assert.rejects(import(`../utils/jwt.js?missing-config=${Date.now()}`),/Production requires distinct/);
    } finally {process.env=previous;}
});
test('two concurrent registrations cannot consume a grant twice',async()=>{
    const proof=await grant.issueRegistrationGrant('9999999999','worker');
    queryResult=(sql)=>({rows:sql.includes('INSERT INTO')?[{worker_id:'worker-owner'}]:[]});
    const body={phoneNumber:'9999999999',workerCategory:'PLUMBER',registrationGrant:proof};const a=response(),b=response();
    await Promise.all([worker.registerWorker(req(body),a),worker.registerWorker(req(body),b)]);
    assert.deepEqual([a.code,b.code].sort(),[201,401]);assert.equal(calls.filter(c=>c.sql.includes('INSERT INTO')).length,1);
});
test('two concurrent OTP verifications cannot mint two grants',async()=>{
    cache.set('otp:worker:9999999999','654321');const body={phoneNumber:'9999999999',otp:'654321',role:'worker'};const a=response(),b=response();
    await Promise.all([auth.verifyOtp(req(body),a),auth.verifyOtp(req(body),b)]);
    assert.deepEqual([a.code,b.code].sort(),[200,400]);assert.equal([...cache.keys()].filter(k=>k.startsWith('registration:')).length,1);
});

test('send OTP schema requires explicit app role',async()=>{
    const schemas=await import('../utils/validation.schemas.js');
    assert.throws(()=>schemas.sendOtpSchema.parse({phoneNumber:'9999999999'}));
    assert.equal((schemas.sendOtpSchema.parse({phoneNumber:'9999999999',role:'employer'}) as any).role,'employer');
});
test('role-specific OTP cannot verify the other app or consume its challenge',async()=>{
    cache.set('otp:worker:9999999999','654321');const employerRes=response();
    await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role:'employer'}),employerRes);
    assert.equal(employerRes.code,400);assert.equal(calls.length,0);assert.equal(cache.get('otp:worker:9999999999'),'654321');
    const workerRes=response();await auth.verifyOtp(req({phoneNumber:'9999999999',otp:'654321',role:'worker'}),workerRes);
    assert.equal(workerRes.code,200);assert.equal(workerRes.data.role,'worker');assert.ok(workerRes.data.registrationGrant);
});
test('same phone with both accounts logs in only requested role using fresh respective OTP',async()=>{
    queryResult=sql=>({rows:sql.includes('FROM workers')?[{worker_id:'worker-owner'}]:[{employer_id:'employer-owner'}]});
    for(const role of ['worker','employer'] as const) {
        cache.set(`otp:${role}:9999999999`,role==='worker'?'654321':'987654');const res=response();
        await auth.verifyOtp(req({phoneNumber:'9999999999',otp:role==='worker'?'654321':'987654',role}),res);
        assert.equal(res.code,200);assert.equal(res.data.isNewUser,false);
        assert.equal(jwt.verifyAccessToken(res.data.token).userId,actors[role].userId);
        assert.equal(jwt.verifyRefreshToken(res.data.refreshToken).role,role);assert.equal(res.data.registrationGrant,undefined);
    }
});
test('second-role grant cannot enroll existing other role and never grants an access session itself',async()=>{
    const proof=await grant.issueRegistrationGrant('9999999999','employer');
    assert.throws(()=>jwt.verifyAccessToken(proof));const res=response();
    await worker.registerWorker(req({phoneNumber:'9999999999',workerCategory:'PLUMBER',registrationGrant:proof}),res);
    assert.equal(res.code,401);assert.equal(calls.length,0);assert.equal(res.data.token,undefined);
});

test('send OTP stores role-specific challenge, phone-wide abuse limits, and calls only fake SMS',async()=>{
    const sent:any[]=[];fixtureSms=async(params)=>{sent.push(params);return {success:true,simulated:true};};
    const res=response();await auth.sendOtp(req({phoneNumber:'9999999999',role:'employer'}),res);
    assert.equal(res.code,200);assert.equal(res.data.role,'employer');assert.equal(sent.length,1);
    assert.match(cache.get('otp:employer:9999999999')!,/^\d{6}$/);
    assert.equal(cache.has('otp:worker:9999999999'),false);assert.equal(cache.has('otp:9999999999'),false);
    assert.equal(cache.get('otp_cooldown:9999999999'),'1');assert.equal(cache.get('otp_hourly:9999999999'),'1');
    const workerAttempt=response();await auth.sendOtp(req({phoneNumber:'9999999999',role:'worker'}),workerAttempt);
    assert.equal(workerAttempt.code,429);assert.equal(sent.length,1);
});

test('status/profile reads never override explicit offline choice or republish location',async()=>{
    queryResult=(sql)=>({rows:sql.includes('FROM workers')?[{worker_id:'worker-owner',is_available:false}]:[]});
    for(const fn of [worker.getWorkerStatus,worker.getWorkerMyProfile]){calls.length=0;const res=response();await fn(req({}, {workerId:'worker-owner'},actors.worker),res);assert.equal(res.code,200);assert.ok(calls.every(c=>!c.sql.trim().startsWith('UPDATE')));}
});
