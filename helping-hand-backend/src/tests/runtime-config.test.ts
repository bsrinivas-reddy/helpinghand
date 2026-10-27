import {test,mock}from'node:test';import assert from'node:assert/strict';
process.env.NODE_ENV='test';process.env.JWT_SECRET='fixture-access-secret';process.env.JWT_REFRESH_SECRET='fixture-refresh-secret';process.env.GOOGLE_CLIENT_ID='client.apps.googleusercontent.com';
let payload:any={sub:'real-sub',email:'real@example.com',email_verified:true,name:'R'};
class FakeClient{async verifyIdToken(){return {getPayload:()=>payload};}generateAuthUrl(){return '';}async getToken(){return {tokens:{}};}setCredentials(){}}
mock.module('google-auth-library',{namedExports:{OAuth2Client:FakeClient}});
const {isDevShortcutEnv,corsOrigin,trustProxyHops}=await import('../config/runtime.js');
const {signAccessToken}=await import('../utils/jwt.js');
const {sendTwilioSms}=await import('../services/twilioService.js');
const {verifyGoogleIdToken}=await import('../services/googleAuth.service.js');
test('dev shortcuts need an explicitly named dev or test environment',()=>{
    assert.equal(isDevShortcutEnv({NODE_ENV:'development'}),true);
    assert.equal(isDevShortcutEnv({NODE_ENV:'test'}),true);
    for(const v of [undefined,'','production','prod','staging','Development'])assert.equal(isDevShortcutEnv({NODE_ENV:v}),false);
});
test('mock Google token is honoured in test, ignored when NODE_ENV is unset or misspelt',async()=>{
    const mockToken='mock-google-token:attacker@example.com:X:evil-sub';
    assert.equal((await verifyGoogleIdToken(mockToken)).googleId,'evil-sub');
    const saved=process.env.NODE_ENV;
    try{
        for(const v of [undefined,'prod','staging']){
            if(v===undefined)delete process.env.NODE_ENV;else process.env.NODE_ENV=v;
            const p=await verifyGoogleIdToken(mockToken);
            assert.equal(p.googleId,'real-sub');assert.equal(p.email,'real@example.com');
        }
    }finally{process.env.NODE_ENV=saved;}
});
test('CORS: no list means no browser access outside dev; wildcard is refused outside dev',()=>{
    assert.equal(corsOrigin({NODE_ENV:'production'}),false);
    assert.equal(corsOrigin({}),false);
    assert.equal(corsOrigin({NODE_ENV:'development'}),'*');
    assert.deepEqual(corsOrigin({NODE_ENV:'production',CORS_ORIGINS:' https://a.example , https://b.example '}),['https://a.example','https://b.example']);
    assert.throws(()=>corsOrigin({NODE_ENV:'production',CORS_ORIGINS:'*'}),/explicit origins/);
});
test('TRUST_PROXY defaults to 0 and rejects junk',()=>{
    assert.equal(trustProxyHops({}),0);assert.equal(trustProxyHops({TRUST_PROXY:'1'}),1);
    for(const v of ['true','-1','1.5','11','abc'])assert.throws(()=>trustProxyHops({TRUST_PROXY:v}),/TRUST_PROXY/);
});

const withEnv=async(v:string|undefined,fn:()=>Promise<void>|void)=>{const saved=process.env.NODE_ENV;if(v===undefined)delete process.env.NODE_ENV;else process.env.NODE_ENV=v;try{await fn();}finally{process.env.NODE_ENV=saved;}};
test('JWT built-in fallback secrets need a named dev/test env; unset or misspelt NODE_ENV fails closed',async()=>{
    const saved={a:process.env.JWT_SECRET,r:process.env.JWT_REFRESH_SECRET};
    delete process.env.JWT_SECRET;delete process.env.JWT_REFRESH_SECRET;
    try{
        await withEnv('test',()=>{assert.ok(signAccessToken({id:'u',role:'worker'} as any));});
        for(const v of [undefined,'prod','staging'])await withEnv(v,()=>{assert.throws(()=>signAccessToken({id:'u',role:'worker'} as any),/distinct configured/);});
    }finally{process.env.JWT_SECRET=saved.a;process.env.JWT_REFRESH_SECRET=saved.r;}
});
test('SMS simulation without Twilio credentials only in dev/test; otherwise it throws',async()=>{
    const keys=['TWILIO_ACCOUNT_SID','TWILIO_AUTH_TOKEN','TWILIO_PHONE_NUMBER'];const saved=keys.map(k=>process.env[k]);keys.forEach(k=>delete process.env[k]);
    try{
        await withEnv('test',async()=>{assert.equal((await sendTwilioSms({to:'9999999999',body:'x'})).simulated,true);});
        for(const v of [undefined,'prod','production'])await withEnv(v,async()=>{await assert.rejects(sendTwilioSms({to:'9999999999',body:'x'}),/must be configured/);});
    }finally{keys.forEach((k,i)=>{if(saved[i]!==undefined)process.env[k]=saved[i];});}
});
test('CORS entries must be bare origins; wildcard mixed with origins is refused outside dev',()=>{
    for(const bad of ['null','https://a.example/','https://*.a.example','a.example','ftp://a.example','https://a.example/path'])assert.throws(()=>corsOrigin({NODE_ENV:'production',CORS_ORIGINS:bad}),/bare origin/,bad);
    assert.throws(()=>corsOrigin({NODE_ENV:'production',CORS_ORIGINS:'https://a.example,*'}),/explicit origins/);
    assert.deepEqual(corsOrigin({NODE_ENV:'production',CORS_ORIGINS:'https://a.example:8443'}),['https://a.example:8443']);
    assert.throws(()=>corsOrigin({NODE_ENV:'production',CORS_ORIGINS:'http://a.example'}),/https/);
    assert.deepEqual(corsOrigin({NODE_ENV:'development',CORS_ORIGINS:'http://localhost:5173'}),['http://localhost:5173']);
    assert.equal(corsOrigin({NODE_ENV:'test'}),'*');
});
test('TRUST_PROXY rejects hex and exponent notation',()=>{for(const v of ['0x2','1e1',' 2','+1'])assert.throws(()=>trustProxyHops({TRUST_PROXY:v}),/TRUST_PROXY/,v);});
