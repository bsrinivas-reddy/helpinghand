import crypto from 'crypto';import redis from '../db/redisClient.js';import {FlowError,transaction} from './shiftState.service.js';import pool from '../db/db.js';import {calculateHaversineDistance} from '../utils/haversine.js';
const validPosition=(lat:number,lng:number)=>Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=-90&&lat<=90&&lng>=-180&&lng<=180;
const validMoney=(n:number)=>Number.isFinite(n)&&n>0&&Math.abs(n*100-Math.round(n*100))<0.000001;
const key=(id:string)=>`shift_handshake:${id}`;
export const initiateCash=async(id:string,workerId:string,data:any):Promise<any>=>transaction(async db=>{
    if(data.cashReceived!==true||!validPosition(data.lat,data.lng)||!validMoney(data.cashAmount))throw new FlowError(400,'Valid cash receipt acknowledgement required');
    const result=await db.query('SELECT * FROM shifts WHERE shift_id=$1 AND worker_id=$2 FOR UPDATE',[id,workerId]);const shift=result.rows[0];
    if(!shift)throw new FlowError(404,'Shift not found');if(shift.status!=='ACTIVE')throw new FlowError(409,'Cash acknowledgement requires active shift');
    const code=crypto.randomInt(1000,10000).toString();
    await redis.set(key(id),JSON.stringify({code,shiftId:id,workerId,employerId:shift.employer_id,lat:data.lat,lng:data.lng,amount:data.cashAmount,createdAt:Date.now()}),{EX:600});
    await redis.del(`${key(id)}:attempts`);
    return {success:true,shiftId:id,handshakeCode:code,expiresInSeconds:600,message:'Cash receipt acknowledged. Share code only with this employer after checking amount.'};
});
export const completeCash=async(id:string,employerId:string,data:any):Promise<any>=>{
    if(data.cashPaid!==true||!validPosition(data.employerLat,data.employerLng)||!validMoney(data.cashAmount)||!/^\d{4}$/.test(data.handshakeCode??''))throw new FlowError(400,'Valid cash payment acknowledgement required');
    const result=await transaction(async db=>{
        const found=await db.query('SELECT * FROM shifts WHERE shift_id=$1 AND employer_id=$2 FOR UPDATE',[id,employerId]);const shift=found.rows[0];
        if(!shift)throw new FlowError(404,'Shift not found');
        if(shift.status==='COMPLETED'){
            if(Number(shift.actual_cash_paid)!==data.cashAmount)throw new FlowError(409,'Completed cash amount is immutable');
            return {success:true,shift,retry:true,message:'Previously recorded cash acknowledgement retained',proximityVerified:false};
        }
        if(shift.status!=='ACTIVE')throw new FlowError(409,'Cash acknowledgement requires active shift');
        const raw=await redis.get(key(id));if(!raw)throw new FlowError(409,'Cash handshake expired or missing');
        const session=JSON.parse(raw);
        if(session.workerId!==shift.worker_id||session.employerId!==employerId||session.shiftId!==id||Date.now()-session.createdAt>600000)throw new FlowError(409,'Cash handshake invalid or stale');
        const attempts=Number(await redis.get(`${key(id)}:attempts`)??0);if(attempts>=5)throw new FlowError(429,'Cash code attempt limit reached');
        if(session.code!==data.handshakeCode){await redis.incr(`${key(id)}:attempts`);await redis.expire(`${key(id)}:attempts`,600);throw new FlowError(400,'Invalid cash handshake code');}
        if(session.amount!==data.cashAmount)throw new FlowError(409,'Cash amount does not match worker acknowledgement');
        const distanceMeters=Math.round(calculateHaversineDistance(session.lat,session.lng,data.employerLat,data.employerLng));
        if(distanceMeters>50)throw new FlowError(409,'Reported device positions exceed50m; cash not recorded');
        const scheduledTime=new Date(Date.now()+5*60000);
        const updated=await db.query("UPDATE shifts SET status='COMPLETED',actual_cash_paid=$1,end_time=COALESCE(end_time,CURRENT_TIMESTAMP),verification_call_status='SCHEDULED',verification_scheduled_at=$2 WHERE shift_id=$3 AND employer_id=$4 AND status='ACTIVE' RETURNING *",[data.cashAmount,scheduledTime,id,employerId]);
        if(!updated.rows.length)throw new FlowError(409,'Shift changed; refresh');
        await db.query('UPDATE workers SET is_available=false WHERE worker_id=$1',[shift.worker_id]);
        return {success:true,shift:updated.rows[0],distanceMeters,proximityVerified:false,reportedPositionsWithinThreshold:true,callScheduled:{scheduled:true,scheduledTime},message:'Both parties acknowledged the same cash amount; device-reported proximity recorded, not independently verified'};
    });
    // Failure after commit is a safe retry, never a reason to overwrite amount or redial.
    try{await redis.del(key(id));}catch{ /* TTL + terminal SQL guard retain safety */ }
    return result;
};
