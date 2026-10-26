import {test,mock} from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import {IncomingMessage,ServerResponse} from 'node:http';
import express from 'express';
mock.method(net.Socket.prototype,'connect',()=>{throw new Error('Socket connections forbidden');});
process.env.NODE_ENV='test';process.env.JWT_SECRET='mounted-fixture-access';process.env.JWT_REFRESH_SECRET='mounted-fixture-refresh';
const queries:{sql:string;args:any[]}[]=[];
const query=async(sql:string,args:any[]=[])=>{queries.push({sql,args});return {rows:args[0]==='owned'?[{shift_id:'owned',worker_id:'worker-owner',employer_id:'employer-owner'}]:[]};};
mock.module(new URL('../db/db.js',import.meta.url).href,{defaultExport:{query}});
const forbidden=()=>{throw new Error('Unexpected cache/provider use');};
mock.module(new URL('../db/redisClient.js',import.meta.url).href,{defaultExport:{get:forbidden,set:forbidden,del:forbidden,eval:forbidden}});
mock.module(new URL('../services/googleAuth.service.js',import.meta.url).href,{namedExports:{verifyGoogleIdToken:forbidden,getGoogleAuthUrl:forbidden,exchangeCodeForProfile:forbidden}});
mock.module(new URL('../services/twilioService.js',import.meta.url).href,{namedExports:{sendTwilioSms:forbidden,makeTwilioIvrCall:forbidden}});
const workerRoutes=(await import('../modules/worker/worker.routes.js')).default;
const employerRoutes=(await import('../modules/employer/employer.routes.js')).default;
const {signAccessToken}=await import('../utils/jwt.js');
const app=express();app.use(express.json());app.use('/api/worker',workerRoutes);app.use('/api/employer',employerRoutes);
// Exercise the actual mounted Express production routers in memory. No listener,
// TCP connection or replacement of route/controller/auth/validation modules.
const request=(url:string,token?:string):Promise<{status:number;body:any}>=>new Promise((resolve,reject)=>{
    const socket=new net.Socket();
    const req=new IncomingMessage(socket);req.method='POST';req.url=url;
    req.headers={'content-type':'application/json','content-length':'2',...(token?{authorization:`Bearer ${token}`}:{})};
    const res=new ServerResponse(req);
    res.end=((chunk:any)=>{try{resolve({status:res.statusCode,body:JSON.parse(String(chunk))});}catch(error){reject(error);}return res;})as any;
    (app as any).handle(req,res,(error?:any)=>{if(error)reject(error);else reject(new Error('Unexpected route fallthrough'));});
    req.push('{}');req.push(null);
});
for(const role of ['worker','employer'] as const){
    const token=signAccessToken({userId:`${role}-owner`,role});const wrong=signAccessToken({userId:'other',role:role==='worker'?'employer':'worker'});
    for(const [label,id,credential,status] of [['owned','owned',token,409],['missing token','owned',undefined,401],['wrong role','owned',wrong,403],['foreign','foreign',token,404]] as const){
        test(`mounted ${role} empty reconcile: ${label} -> ${status}`,async()=>{
            queries.length=0;const result=await request(`/api/${role}/shifts/${id}/reconcile-cash`,credential);
            assert.equal(result.status,status);
            if(status===409)assert.equal(result.body.error,'handshake_required');
            if(status===401||status===403)assert.equal(queries.length,0);
            else{assert.equal(queries.length,1);assert.ok(queries[0].sql.includes(`${role}_id = $2`));assert.equal(queries[0].args[1],`${role}-owner`);}
        });
    }
}
