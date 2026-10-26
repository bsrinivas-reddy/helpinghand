import {verificationConfig} from '../utils/verificationConfig.js';
import pool from '../db/db.js';
import redis from '../db/redisClient.js';
import crypto from 'crypto';
import {makeTwilioIvrCall} from './twilioService.js';
import {dispatchBindingKey} from '../middlewares/ivr.middleware.js';
import {FlowError,transaction} from './shiftState.service.js';
export interface IvrDispatchParams {shiftId:string;workerPhone:string;employerPhone:string;agreedWage:number;}
const e164=(phone:string):string=>phone.startsWith('+')?phone:phone.length===10?`+91${phone}`:`+${phone}`;
export const dispatchIvrCalls=async(params:IvrDispatchParams):Promise<{success:boolean;message:string;status:string}>=>{
    const results=await Promise.allSettled((['worker','employer'] as const).map(async role=>{
        const nonce=crypto.randomBytes(32).toString('hex');
        const to=e164(role==='worker'?params.workerPhone:params.employerPhone);
        await redis.set(dispatchBindingKey(nonce),JSON.stringify({shiftId:params.shiftId,role,to}),{EX:verificationConfig().bindingSeconds});
        const result=await makeTwilioIvrCall({to,shiftId:params.shiftId,role,agreedWage:params.agreedWage,dispatchNonce:nonce});
        if(!result.success||result.simulated||!result.sid)throw new Error('No real dispatch evidence');
        const bound=await redis.eval("local raw=redis.call('GET',KEYS[1]); if not raw then return 0 end; local b=cjson.decode(raw); if b.callSid and b.callSid~=ARGV[1] then return 0 end; b.callSid=ARGV[1]; redis.call('SET',KEYS[1],cjson.encode(b),'KEEPTTL'); return 1",{keys:[dispatchBindingKey(nonce)],arguments:[result.sid]});
        if(!bound)throw new Error('Dispatch binding missing or inconsistent');
        return result.sid;
    }));
    const count=results.filter(r=>r.status==='fulfilled').length;
    const status=count===2?'DISPATCHED':count===1?'PARTIAL':'UNKNOWN';
    // Never reverse a dispute/verification that arrived during provider dispatch.
    await pool.query("UPDATE shifts SET verification_call_status = $1 WHERE shift_id = $2 AND verification_call_status = 'DISPATCHING'",[status,params.shiftId]);
    return {success:count===2,status,message:count===2?'Both calls accepted by provider, awaiting responses':'Dispatch incomplete or unknown; manual review required, no automatic retry'};
};
export const processIvrKeypress=async(shiftId:string,role:'worker'|'employer',digit:string):Promise<{success:boolean;shiftStatus:string;message:string}>=>transaction(async db=>{
    if(!['worker','employer'].includes(role)||!['1','2'].includes(digit))throw new FlowError(400,'Invalid callback response');
    const found=await db.query('SELECT * FROM shifts WHERE shift_id = $1 FOR UPDATE',[shiftId]);const shift=found.rows[0];
    if(!shift)throw new FlowError(404,'Shift not found');
    if(shift.status!=='COMPLETED'||!['DISPATCHING','DISPATCHED','PARTIAL','UNKNOWN','VERIFIED','DISPUTED'].includes(shift.verification_call_status))throw new FlowError(409,'Unexpected verification state');
    const column=role==='worker'?'worker_call_confirmed':'employer_call_confirmed';
    if(shift.verification_call_status==='DISPUTED')return {success:true,shiftStatus:'DISPUTED',message:'Dispute retained'};
    if(digit==='1'&&shift[column])return {success:true,shiftStatus:shift.verification_call_status,message:'Response already recorded'};
    const worker=role==='worker'?digit==='1':shift.worker_call_confirmed===true;
    const employer=role==='employer'?digit==='1':shift.employer_call_confirmed===true;
    const status=digit==='2'?'DISPUTED':worker&&employer?'VERIFIED':shift.verification_call_status;
    await db.query(`UPDATE shifts SET ${column} = $1, verification_call_status = $2 WHERE shift_id = $3`,[digit==='1',status,shiftId]);
    return {success:true,shiftStatus:status,message:status==='DISPUTED'?'Dispute recorded':'Party response recorded'};
});
